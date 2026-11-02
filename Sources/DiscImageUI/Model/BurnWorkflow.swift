import DiscImageCore
import Foundation

/// 刻录页的状态机（UI 与测试共用）。
///
/// 安全约定：
/// 1. 任何刻录动作都必须先 `prepareBurn` 进入 `.needsConfirmation`；
/// 2. 只有显式 `confirmAndBurn()` 才会调用 `BurnServicing.burn`（二次确认）；
/// 3. 介质非空白、设备未选、镜像文件不存在一律拒绝，并且不产生任何副作用。
@MainActor
public final class BurnWorkflow: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case scanning
        case ready
        case needsConfirmation(BurnJobRequest)
        case burning
        case finished(String)
        case cancelled
        case failed(String)

        public var isBusy: Bool {
            self == .burning || self == .scanning
        }
    }

    public let service: BurnServicing

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var devices: [BurnDeviceInfo] = []
    @Published public private(set) var selectedDeviceID: String?
    @Published public private(set) var mediaStatus: BurnMediaStatus = .noMedia
    @Published public private(set) var speeds: [BurnSpeed] = [.automatic]
    @Published public private(set) var selectedSpeed: BurnSpeed = .automatic
    @Published public private(set) var progress: BurnProgressInfo = BurnProgressInfo(message: "尚未开始")
    @Published public private(set) var pendingRequest: BurnJobRequest?

    private var cancellation: CancellationFlag?

    public init(service: BurnServicing = BurnServiceProvider.makeDefault()) {
        self.service = service
    }

    public var serviceName: String { service.serviceName }

    public var selectedDevice: BurnDeviceInfo? {
        devices.first { $0.id == selectedDeviceID }
    }

    /// 二次确认时展示的警告文案。
    public var confirmationMessage: String {
        let device = selectedDevice?.resolvedDisplayName ?? selectedDeviceID ?? "所选设备"
        return "即将向「\(device)」写入镜像。刻录过程中请勿退出应用或断电；"
            + "若刻录失败，这张盘可能报废。确认继续？"
    }

    /// 枚举设备（`drutil list` 的 UI 侧替身）。失败时进入 `.failed`，不抛出。
    public func refreshDevices() {
        guard !phase.isBusy else { return }
        phase = .scanning
        do {
            let found = try service.enumerateDevices()
            devices = found
            if let first = found.first {
                selectedDeviceID = first.id
                try selectDevice(first.id)
            } else {
                selectedDeviceID = nil
                mediaStatus = .noMedia
                speeds = [.automatic]
                selectedSpeed = .automatic
                phase = .failed("没有检测到刻录机。请连接外置刻录机后重试。")
            }
        } catch {
            devices = []
            selectedDeviceID = nil
            phase = .failed(Self.message(for: error))
        }
    }

    /// 选择倍速（drutil 只提供「自动」时界面上就只有一项）。
    public func selectSpeed(_ speed: BurnSpeed) {
        guard speeds.contains(speed) else { return }
        selectedSpeed = speed
    }

    /// 选中设备并读取介质状态/倍速。
    public func selectDevice(_ deviceID: String) throws {
        selectedDeviceID = deviceID
        do {
            mediaStatus = try service.mediaStatus(for: deviceID)
            speeds = try service.availableSpeeds(for: deviceID)
            if !speeds.contains(selectedSpeed) {
                selectedSpeed = speeds.first(where: { $0.factor > 0 }) ?? .automatic
            }
            phase = .ready
        } catch {
            mediaStatus = .unknown(Self.message(for: error))
            speeds = [.automatic]
            selectedSpeed = .automatic
            phase = .ready
        }
    }

    /// 第一步：检查一切前置条件，进入二次确认。**不会**触发刻录。
    public func prepareBurn(
        imageURL: URL,
        format: GenerationOutputFormat,
        volumeLabel: String = "DISC_IMAGE",
        ejectWhenFinished: Bool = true
    ) throws {
        guard !phase.isBusy else {
            throw DiscError.unsupported("当前有任务在进行，请等待完成或取消。")
        }
        guard let deviceID = selectedDeviceID else {
            phase = .failed("请先选择刻录机。")
            throw DiscError.unsupported("请先选择刻录机。")
        }
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            let message = "找不到要刻录的镜像：\(imageURL.lastPathComponent)。请先在导出页生成。"
            phase = .failed(message)
            throw DiscError.io(message)
        }
        guard mediaStatus.isBlank else {
            let message = "介质不是空白：\(mediaStatus.displayNameZH)。请换一张空白盘，或先清空可重写盘。"
            phase = .failed(message)
            throw DiscError.unsupported(message)
        }

        let request = BurnJobRequest(
            imageURL: imageURL,
            mediaKind: Self.mediaKind(for: format),
            deviceID: deviceID,
            speed: selectedSpeed,
            volumeLabel: volumeLabel,
            ejectWhenFinished: ejectWhenFinished
        )
        pendingRequest = request
        phase = .needsConfirmation(request)
    }

    /// 第二步：用户点了「确认刻录」之后才真正执行。
    public func confirmAndBurn() async {
        guard case .needsConfirmation(let request) = phase else { return }
        let cancellation = CancellationFlag()
        self.cancellation = cancellation
        phase = .burning
        progress = BurnProgressInfo(message: "开始刻录…", fraction: 0)

        let service = self.service
        let workflow = self
        do {
            let outcome = try await Task.detached(priority: .userInitiated) { [service, request, cancellation, workflow] in
                try service.burn(
                    request,
                    progress: { info in
                        Task { @MainActor in
                            guard workflow.phase == .burning else { return }
                            workflow.progress = info
                        }
                    },
                    cancellation: cancellation
                )
            }.value

            pendingRequest = nil
            switch outcome {
            case .finished(let message):
                phase = .finished(message)
            case .cancelled:
                phase = .cancelled
            }
        } catch is CancellationError {
            pendingRequest = nil
            phase = .cancelled
        } catch {
            pendingRequest = nil
            phase = .failed(Self.message(for: error))
        }
    }

    public func cancel() {
        cancellation?.cancel()
        if phase == .burning {
            phase = .cancelled
        }
    }

    /// 回到可再次操作的状态（不改变设备与介质状态）。
    public func resetPhase() {
        guard !phase.isBusy else { return }
        pendingRequest = nil
        progress = BurnProgressInfo(message: "尚未开始")
        phase = selectedDeviceID == nil ? .idle : .ready
    }

    public static func mediaKind(for format: GenerationOutputFormat) -> BurnJobRequest.MediaKind {
        switch format {
        case .wav, .raw: return .audio
        case .iso: return .data
        }
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
