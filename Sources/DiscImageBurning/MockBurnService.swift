import Foundation

/// 内存里的假刻录机：给界面预览、无光驱开发和单元测试用。
///
/// 它**不会**调用 `drutil` / `hdiutil`，也不会启动任何子进程，所以在没有刻录机
/// 的机器和 CI 上都能随便用。默认配置模拟「一台 USB 刻录机 + 一张空白 CD-R」。
///
/// 用法：
/// ```swift
/// let mock = MockBurnService()                    // 一台设备、空白 CD
/// let status = try await mock.status(deviceID: nil)
/// mock.calls                                      // 记录了界面对后端做了什么
/// ```
/// 想验证错误路径时用 `MockBurnService(devices: [], ...)`（无设备）或
/// `MockBurnService(failure: .discNotBlank(mediaType: "DVD-R"))`。
public struct MockBurnService: BurnService {
    /// 记录到的一次调用（顺序即界面行为）。
    public enum Call: Sendable, Equatable {
        case listDevices
        case status(deviceID: String?)
        case burnAudio(trackURL: URL, deviceID: String?)
        case burnImage(imageURL: URL, deviceID: String?)
        case eject(deviceID: String?)
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [Call] = []

        func record(_ call: Call) {
            lock.lock()
            calls.append(call)
            lock.unlock()
        }

        var snapshot: [Call] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }

        func reset() {
            lock.lock()
            calls.removeAll()
            lock.unlock()
        }
    }

    private let state = State()
    private let devices: [DiscDevice]
    private let mediaStatus: DiscStatus
    private let failure: BurnError?
    /// 每次「刻录」模拟耗时（纳秒）；用来让界面看清进度/取消。
    private let burnDelayNanoseconds: UInt64
    private let progress: (@Sendable (BurnProgress) -> Void)?

    public init(
        devices: [DiscDevice] = MockBurnService.simulatedDevices,
        status: DiscStatus = MockBurnService.blankCDStatus,
        failure: BurnError? = nil,
        burnDelayNanoseconds: UInt64 = 0,
        progress: (@Sendable (BurnProgress) -> Void)? = nil
    ) {
        self.devices = devices
        self.mediaStatus = status
        self.failure = failure
        self.burnDelayNanoseconds = burnDelayNanoseconds
        self.progress = progress
    }

    /// 界面里调用过的操作（按顺序）。
    public var calls: [Call] { state.snapshot }

    /// 清空调用记录（界面重新打开刻录页时用）。
    public func resetCalls() { state.reset() }

    // MARK: - BurnService

    public func listDevices() async throws -> [DiscDevice] {
        state.record(.listDevices)
        try await failIfConfigured()
        return devices
    }

    public func status(deviceID: String?) async throws -> DiscStatus {
        state.record(.status(deviceID: deviceID))
        try await failIfConfigured()
        if devices.isEmpty { throw BurnError.noDevice }
        return mediaStatus
    }

    public func burnAudio(trackURL: URL, deviceID: String?) async throws {
        state.record(.burnAudio(trackURL: trackURL, deviceID: deviceID))
        try await failIfConfigured()
        try await simulateBurn(stage: .writing)
    }

    public func burnImage(imageURL: URL, deviceID: String?) async throws {
        state.record(.burnImage(imageURL: imageURL, deviceID: deviceID))
        try await failIfConfigured()
        try await simulateBurn(stage: .writing)
    }

    public func eject(deviceID: String?) async throws {
        state.record(.eject(deviceID: deviceID))
        try await failIfConfigured()
    }

    // MARK: - 内部

    private func failIfConfigured() async throws {
        if let failure {
            // 让取消路径也能被测试：先睡一小会，再抛预置错误。
            try await sleepIfNeeded()
            throw failure
        }
    }

    private func simulateBurn(stage: BurnProgress.Stage) async throws {
        progress?(BurnProgress(stage: .preparing, fraction: 0, rawLine: "开始刻录（模拟）"))
        try await sleepIfNeeded()
        progress?(BurnProgress(stage: stage, fraction: 0.5, rawLine: "写入中（模拟）"))
        try await sleepIfNeeded()
        progress?(BurnProgress(stage: .completed, fraction: 1, rawLine: "刻录完成（模拟）"))
    }

    private func sleepIfNeeded() async throws {
        guard burnDelayNanoseconds > 0 else { return }
        try await Task.sleep(nanoseconds: burnDelayNanoseconds)
    }

    // MARK: - 预置样本

    /// 默认模拟的两台设备（一台 CD/DVD SuperDrive、一台蓝光刻录机）。
    public static let simulatedDevices: [DiscDevice] = [
        DiscDevice(
            id: "1",
            vendor: "Apple",
            product: "SuperDrive",
            bus: "USB",
            supportLevel: "cd-r,cd-rw,dvd-r,dvd-rw"
        ),
        DiscDevice(
            id: "2",
            vendor: "HL-DT-ST",
            product: "BD-RE WH16NS40",
            bus: "USB",
            supportLevel: "cd-r,cd-rw,dvd-r,dvd-ram,bd-r,bd-re"
        ),
    ]

    /// 一张空白 CD-R（700 MB）。
    public static let blankCDStatus = DiscStatus(
        isBlank: true,
        mediaType: "CD-R",
        capacityBytes: 737_280_000,
        freeBytes: 737_280_000,
        isWritable: true
    )

    /// 一张已经烧过内容的 DVD-R。
    public static let usedDVDStatus = DiscStatus(
        isBlank: false,
        mediaType: "DVD-R",
        capacityBytes: 4_707_319_808,
        freeBytes: 0,
        isWritable: false
    )

    /// 没有插盘的状态。
    public static let noMediaStatus = DiscStatus(
        isBlank: false,
        mediaType: "",
        capacityBytes: 0,
        freeBytes: 0,
        isWritable: false
    )

    /// 模拟「没有接刻录机」。
    public static let noDevice = MockBurnService(devices: [])
}
