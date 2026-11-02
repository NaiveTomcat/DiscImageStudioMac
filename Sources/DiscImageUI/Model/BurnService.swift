import DiscImageCore
import Foundation

/// 一台可用刻录机。
///
/// 这是 **UI 侧**的抽象：工作包 E（`DiscImageBurning`）的真实类型在它自己的模块里，
/// UI 只通过下面的 `BurnServicing` 协议与它对接（见 `BurnServiceProvider` 的接线点注释）。
public struct BurnDeviceInfo: Identifiable, Equatable, Sendable {
    /// `drutil` 的 `-/dev/disk4` 之类标识。
    public var id: String
    public var displayName: String
    public var vendor: String
    public var product: String

    public init(id: String, displayName: String? = nil, vendor: String = "", product: String = "") {
        self.id = id
        self.displayName = displayName ?? [vendor, product].filter { !$0.isEmpty }.joined(separator: " ")
        self.vendor = vendor
        self.product = product
    }

    public var resolvedDisplayName: String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? id : name
    }
}

/// 设备里的介质状态。刻录前必须确认「空白」。
public enum BurnMediaStatus: Equatable, Sendable {
    /// 没有插盘。
    case noMedia
    /// 空白可写介质。
    case blank(mediaLabel: String, capacityBytes: Int64)
    /// 已有内容（只读或不可再写），不能覆盖刻录。
    case notBlank(mediaLabel: String)
    /// 设备报告了无法识别的状态。
    case unknown(String)

    public var isBlank: Bool {
        if case .blank = self { return true }
        return false
    }

    public var displayNameZH: String {
        switch self {
        case .noMedia: return "未检测到介质"
        case .blank(let label, let capacity):
            let gigabytes = Double(capacity) / 1_000_000_000
            return "空白 \(label)（\(String(format: "%.1f", gigabytes)) GB）"
        case .notBlank(let label): return "非空白介质 \(label)"
        case .unknown(let detail): return "状态未知：\(detail)"
        }
    }
}

/// 刻录倍速选项。
public struct BurnSpeed: Identifiable, Equatable, Hashable, Sendable {
    /// 倍速（1x = 150 KiB/s，UI 只显示倍数）。
    public var factor: Double
    public var label: String

    public var id: String { label }

    public init(factor: Double) {
        self.factor = factor
        self.label = factor <= 0 ? "自动" : String(format: "%.0fx", factor)
    }

    public static let automatic = BurnSpeed(factor: 0)
}

/// 一次刻录请求。刻录永远基于已导出的镜像文件，生成与刻录解耦（HANDOFF §3.4）。
public struct BurnJobRequest: Equatable, Sendable {
    public enum MediaKind: String, Equatable, Sendable {
        case data = "数据盘"
        case audio = "CD-DA 音频"
    }

    public var imageURL: URL
    public var mediaKind: MediaKind
    public var deviceID: String
    public var speed: BurnSpeed
    public var volumeLabel: String
    public var ejectWhenFinished: Bool

    public init(
        imageURL: URL,
        mediaKind: MediaKind,
        deviceID: String,
        speed: BurnSpeed = .automatic,
        volumeLabel: String = "DISC_IMAGE",
        ejectWhenFinished: Bool = true
    ) {
        self.imageURL = imageURL
        self.mediaKind = mediaKind
        self.deviceID = deviceID
        self.speed = speed
        self.volumeLabel = volumeLabel
        self.ejectWhenFinished = ejectWhenFinished
    }
}

public struct BurnProgressInfo: Equatable, Sendable {
    public var message: String
    public var fraction: Double?

    public init(message: String, fraction: Double? = nil) {
        self.message = message
        self.fraction = fraction
    }
}

public enum BurnOutcome: Equatable, Sendable {
    case finished(message: String)
    case cancelled
}

/// UI 依赖的刻录能力。
///
/// 真实实现由工作包 E 的 `DrutilBurner` 提供；这里只定义契约，避免 UI 直接
/// `Process` 调 `drutil`（HANDOFF §6.D / §6.E）。测试用 `MockBurnAdapter`。
public protocol BurnServicing: Sendable {
    /// 服务名（界面上标「drutil」/「模拟」）。
    var serviceName: String { get }
    func enumerateDevices() throws -> [BurnDeviceInfo]
    func mediaStatus(for deviceID: String) throws -> BurnMediaStatus
    func availableSpeeds(for deviceID: String) throws -> [BurnSpeed]
    func burn(
        _ request: BurnJobRequest,
        progress: @escaping @Sendable (BurnProgressInfo) -> Void,
        cancellation: CancellationFlag
    ) throws -> BurnOutcome
}

public extension BurnServicing {
    /// 默认倍速清单：不枚举时也能选「自动」。
    func availableSpeeds(for deviceID: String) throws -> [BurnSpeed] { [.automatic] }
}

/// 工作包 E 落地前的占位实现：界面仍可打开刻录页，但所有操作给出明确中文原因。
public struct UnavailableBurnService: BurnServicing {
    public let serviceName = "未接入"

    public init() {}

    public func enumerateDevices() throws -> [BurnDeviceInfo] {
        throw DiscError.unsupported("刻录服务尚未接入（工作包 E：DiscImageBurning）。")
    }

    public func mediaStatus(for deviceID: String) throws -> BurnMediaStatus {
        throw DiscError.unsupported("刻录服务尚未接入（工作包 E：DiscImageBurning）。")
    }

    public func burn(
        _ request: BurnJobRequest,
        progress: @escaping @Sendable (BurnProgressInfo) -> Void,
        cancellation: CancellationFlag
    ) throws -> BurnOutcome {
        throw DiscError.unsupported("刻录服务尚未接入（工作包 E：DiscImageBurning）。")
    }
}

/// 刻录服务的注入点。
///
/// 工作包 E 已落地，默认返回 `DrutilBurnAdapter`（包装 `DiscImageBurning.DrutilBurner`）；
/// 无光驱的机器、SwiftUI 预览与自动化测试用 `makeMock()`（包装
/// `DiscImageBurning.MockBurnService`）。UI 其它文件只依赖 `BurnServicing`。
public enum BurnServiceProvider {
    /// 默认使用工作包 E 的真机实现（`DrutilBurner`，见 `BurnServiceAdapter.swift`）。
    public static func makeDefault() -> BurnServicing {
        DrutilBurnAdapter()
    }

    /// 没有光驱的机器 / SwiftUI 预览 / 自动化测试用（`DiscImageBurning.MockBurnService`）。
    public static func makeMock() -> BurnServicing {
        MockBurnAdapter()
    }
}
