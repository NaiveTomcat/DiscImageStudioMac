import DiscImageBurning
import DiscImageCore
import Foundation

/// 把工作包 E 的 `BurnService`（async API）适配成 UI 的同步 `BurnServicing`。
///
/// 为什么 UI 用同步协议：刻录页的状态机、二次确认与测试都想写成直白的第一步/第二步；
/// 异步放在这一层桥接。真正的取消靠 `CancellationFlag` 轮询后取消内部 `Task`，
/// `SystemCommandExecutor` 会在 `Task.checkCancellation()` 处终止 `drutil` 子进程。
public struct DrutilBurnAdapter: BurnServicing {
    public let serviceName = "drutil"
    private let imageTool: BurnTool
    private let verifyAfterBurn: Bool

    public init(imageTool: BurnTool = .drutil, verifyAfterBurn: Bool = false) {
        self.imageTool = imageTool
        self.verifyAfterBurn = verifyAfterBurn
    }

    public func enumerateDevices() throws -> [BurnDeviceInfo] {
        do {
            let devices = try AsyncBridge.blockingAwait {
                try await DrutilBurner(executor: SystemCommandExecutor(), imageTool: imageTool, verifyAfterBurn: verifyAfterBurn).listDevices()
            }
            return devices.map(BurnServiceMapping.device)
        } catch BurnError.noDevice {
            return []
        } catch {
            throw BurnServiceMapping.uiError(error)
        }
    }

    public func mediaStatus(for deviceID: String) throws -> BurnMediaStatus {
        do {
            let status = try AsyncBridge.blockingAwait {
                try await DrutilBurner(executor: SystemCommandExecutor(), imageTool: imageTool, verifyAfterBurn: verifyAfterBurn)
                    .status(deviceID: deviceID)
            }
            return BurnServiceMapping.mediaStatus(status)
        } catch BurnError.noMedia {
            return .noMedia
        } catch {
            throw BurnServiceMapping.uiError(error)
        }
    }

    public func availableSpeeds(for deviceID: String) throws -> [BurnSpeed] {
        // drutil 自己决定写入速度；界面只提供「自动」。
        [.automatic]
    }

    public func burn(
        _ request: BurnJobRequest,
        progress: @escaping @Sendable (BurnProgressInfo) -> Void,
        cancellation: CancellationFlag
    ) throws -> BurnOutcome {
        guard FileManager.default.fileExists(atPath: request.imageURL.path) else {
            throw DiscError.io("要刻录的镜像不存在：\(request.imageURL.lastPathComponent)")
        }
        if cancellation.isCancelled { return .cancelled }

        let progressRelay: @Sendable (BurnProgress) -> Void = { burnProgress in
            let message = burnProgress.rawLine.isEmpty
                ? Self.stageText(burnProgress.stage)
                : burnProgress.rawLine
            progress(BurnProgressInfo(message: message, fraction: burnProgress.fraction))
        }
        let burner = DrutilBurner(
            executor: SystemCommandExecutor(),
            imageTool: imageTool,
            verifyAfterBurn: verifyAfterBurn,
            ejectAfterBurn: request.ejectWhenFinished,
            progress: progressRelay
        )
        do {
            try AsyncBridge.blockingAwait(cancellation: cancellation) {
                if cancellation.isCancelled { throw CancellationError() }
                switch request.mediaKind {
                case .audio:
                    try await burner.burnAudio(trackURL: request.imageURL, deviceID: request.deviceID)
                case .data:
                    try await burner.burnImage(imageURL: request.imageURL, deviceID: request.deviceID)
                }
            }
            return .finished(message: "刻录完成：\(request.imageURL.lastPathComponent)")
        } catch is CancellationError {
            return .cancelled
        } catch BurnError.cancelled(_) {
            return .cancelled
        } catch {
            throw BurnServiceMapping.uiError(error)
        }
    }

    static func stageText(_ stage: BurnProgress.Stage) -> String {
        switch stage {
        case .preparing: return "准备写入…"
        case .writing: return "写入中…"
        case .verifying: return "校验中…"
        case .finishing: return "收尾…"
        case .completed: return "刻录完成"
        case .failed: return "刻录失败"
        }
    }
}

/// 包装 `DiscImageBurning.MockBurnService`：没有刻录机的机器上也能跑通整套界面状态机。
public final class MockBurnAdapter: BurnServicing, @unchecked Sendable {
    public let serviceName = "模拟刻录机"
    public let mock: MockBurnService
    private let relay: ProgressRelay

    public init(mock: MockBurnService? = nil) {
        let relay = ProgressRelay()
        self.relay = relay
        self.mock = mock ?? MockBurnService(progress: { info in
            relay.emit(info)
        })
    }

    // MARK: - 测试/预览用的固定配置

    /// 一台模拟刻录机 + 一张空白 CD（默认行为）。
    public static func blankDisc() -> MockBurnAdapter { MockBurnAdapter() }

    /// 没有任何刻录机。
    public static func noDevices() -> MockBurnAdapter {
        MockBurnAdapter(mock: MockBurnService(
            devices: [],
            status: MockBurnService.blankCDStatus,
            failure: .noDevice
        ))
    }

    /// 介质非空白：界面必须拒绝刻录。
    public static func nonBlankDisc(mediaType: String = "DVD-R") -> MockBurnAdapter {
        MockBurnAdapter(mock: MockBurnService(
            status: DiscStatus(
                isBlank: false,
                mediaType: mediaType,
                capacityBytes: 4_700_000_000,
                freeBytes: 0,
                isWritable: false
            )
        ))
    }

    /// 枚举/空白检查都正常、只有刻录失败（后端错误路径）。
    public static func failingBurn() -> BurnServicing {
        FailingBurnProbe()
    }

    /// 真正执行过的刻录次数（确认之前必须为 0）。
    public var burnCallCount: Int {
        mock.calls.filter { call in
            switch call {
            case .burnAudio, .burnImage: return true
            case .listDevices, .status, .eject: return false
            }
        }.count
    }

    /// 最后一次交给后端的镜像路径。
    public var lastBurnURL: URL? {
        for call in mock.calls.reversed() {
            switch call {
            case .burnImage(let url, _): return url
            case .burnAudio(let url, _): return url
            case .listDevices, .status, .eject: continue
            }
        }
        return nil
    }

    public func enumerateDevices() throws -> [BurnDeviceInfo] {
        try AsyncBridge.blockingAwait { [mock] in try await mock.listDevices() }
            .map(BurnServiceMapping.device)
    }

    public func mediaStatus(for deviceID: String) throws -> BurnMediaStatus {
        do {
            let status = try AsyncBridge.blockingAwait { [mock] in try await mock.status(deviceID: deviceID) }
            return BurnServiceMapping.mediaStatus(status)
        } catch BurnError.noMedia {
            return .noMedia
        } catch BurnError.noDevice {
            return .noMedia
        } catch {
            throw BurnServiceMapping.uiError(error)
        }
    }

    public func availableSpeeds(for deviceID: String) throws -> [BurnSpeed] {
        [.automatic, BurnSpeed(factor: 2), BurnSpeed(factor: 4)]
    }

    public func burn(
        _ request: BurnJobRequest,
        progress: @escaping @Sendable (BurnProgressInfo) -> Void,
        cancellation: CancellationFlag
    ) throws -> BurnOutcome {
        if cancellation.isCancelled { return .cancelled }
        relay.setSink { burnProgress in
            let message = burnProgress.rawLine.isEmpty
                ? DrutilBurnAdapter.stageText(burnProgress.stage)
                : burnProgress.rawLine
            progress(BurnProgressInfo(message: message, fraction: burnProgress.fraction))
        }
        defer { relay.setSink(nil) }
        do {
            try AsyncBridge.blockingAwait(cancellation: cancellation) { [mock] in
                switch request.mediaKind {
                case .audio:
                    try await mock.burnAudio(trackURL: request.imageURL, deviceID: request.deviceID)
                case .data:
                    try await mock.burnImage(imageURL: request.imageURL, deviceID: request.deviceID)
                }
            }
            return .finished(message: "模拟刻录完成（未使用真实刻录机）")
        } catch is CancellationError {
            return .cancelled
        } catch BurnError.cancelled(_) {
            return .cancelled
        } catch {
            throw BurnServiceMapping.uiError(error)
        }
    }
}

/// 只让「burn」失败、查询接口正常的测试替身（工作包 E 的 mock 失败时会连枚举一起失败）。
private struct FailingBurnProbe: BurnServicing {
    let serviceName = "模拟刻录机（刻录必失败）"

    func enumerateDevices() throws -> [BurnDeviceInfo] {
        [BurnDeviceInfo(id: "mock:0", displayName: "模拟刻录机", vendor: "Mock", product: "BD-RE")]
    }

    func mediaStatus(for deviceID: String) throws -> BurnMediaStatus {
        .blank(mediaLabel: "模拟 BD-R", capacityBytes: 25_000_000_000)
    }

    func availableSpeeds(for deviceID: String) throws -> [BurnSpeed] { [.automatic] }

    func burn(
        _ request: BurnJobRequest,
        progress: @escaping @Sendable (BurnProgressInfo) -> Void,
        cancellation: CancellationFlag
    ) throws -> BurnOutcome {
        throw DiscError.io("模拟刻录失败")
    }
}

/// 让 `MockBurnService` 的构造期进度闭包能按「本次刻录」转发。
private final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (BurnProgress) -> Void)?

    func setSink(_ newSink: (@Sendable (BurnProgress) -> Void)?) {
        lock.lock()
        sink = newSink
        lock.unlock()
    }

    func emit(_ progress: BurnProgress) {
        lock.lock()
        let current = sink
        lock.unlock()
        current?(progress)
    }
}

/// 类型映射与错误翻译。
enum BurnServiceMapping {
    static func device(_ device: DiscDevice) -> BurnDeviceInfo {
        BurnDeviceInfo(
            id: device.id,
            displayName: device.displayName,
            vendor: device.vendor,
            product: device.product
        )
    }

    static func mediaStatus(_ status: DiscStatus) -> BurnMediaStatus {
        let label = status.mediaType.trimmingCharacters(in: .whitespaces)
        if status.isBlank {
            return .blank(mediaLabel: label.isEmpty ? "空白介质" : label, capacityBytes: status.capacityBytes)
        }
        if label.isEmpty, status.capacityBytes == 0, !status.isWritable {
            return .noMedia
        }
        return .notBlank(mediaLabel: label.isEmpty ? "未知介质" : label)
    }

    /// `BurnError` 自带中文 `errorDescription`，保留它；其它错误转成 `DiscError`。
    static func uiError(_ error: Error) -> Error {
        if error is BurnError { return error }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return DiscError.io(description)
        }
        return DiscError.io(error.localizedDescription)
    }
}

/// 同步/异步桥：给 UI 的同步协议调用 async 后端。
enum AsyncBridge {
    final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<T, Error>?

        func store(_ value: Result<T, Error>) {
            lock.lock()
            result = value
            lock.unlock()
        }

        func take() -> Result<T, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    /// - Parameter cancellation: 非空时每 50 ms 检查一次，取消后取消内部 Task。
    static func blockingAwait<T: Sendable>(
        cancellation: CancellationFlag? = nil,
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        let task = Task.detached(priority: .userInitiated) {
            do {
                box.store(.success(try await operation()))
            } catch {
                box.store(.failure(error))
            }
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
            if let cancellation, cancellation.isCancelled {
                task.cancel()
            }
        }
        guard let result = box.take() else {
            throw DiscError.io("内部错误：异步刻录没有返回结果")
        }
        return try result.get()
    }
}
