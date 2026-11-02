import Foundation

/// 生成进度。`fraction` 为 nil 表示「不知道还要多久」，UI 应显示不确定进度条。
public struct DiscProgress: Sendable, Equatable {
    /// 阶段标识（`geometry` / `mapping` / `ecc` / `modulation` / `filesystem` / `finalize`）。
    public var stage: String
    /// 面向用户的中文说明。
    public var message: String
    public var fraction: Double?

    public init(stage: String, message: String, fraction: Double? = nil) {
        self.stage = stage
        self.message = message
        self.fraction = fraction
    }
}

/// 输出容器格式。
///
/// - `iso`：DVD / BD / CD 数据盘模式（ISO9660 或 UDF 映像）
/// - `wav`：CD-DA，兼容 `drutil burn -audio`（自动旁写同名 `.cue`）
/// - `raw`：CD 裸扇区流，**大端**（源项目的 RAW 输出约定）
public enum GenerationOutputFormat: String, Codable, Sendable, CaseIterable {
    case iso
    case wav
    case raw

    public var displayNameZH: String {
        switch self {
        case .iso: return "ISO 映像"
        case .wav: return "WAV + CUE 音频"
        case .raw: return "RAW 扇区流"
        }
    }

    public var fileExtension: String {
        switch self {
        case .iso: return "iso"
        case .wav: return "wav"
        case .raw: return "raw"
        }
    }

    public static func options(for family: DiscFamily) -> [GenerationOutputFormat] {
        switch family {
        case .cd: return [.wav, .raw, .iso]
        case .dvd, .bluRay: return [.iso]
        }
    }
}

/// 一次生成请求。图片与几何是必需项；`dataDirectory` 非空即「数据盘模式」。
public struct GenerationRequest: Sendable {
    public var geometry: DiscGeometry
    public var tone: ToneProfile
    public var image: RasterImage
    /// 输出格式；决定引擎走音频轨还是数据盘链路。
    public var outputFormat: GenerationOutputFormat
    /// 要写进盘里的文件夹（nil = 纯绘图刻录，只编码图像）。
    public var dataDirectory: URL?
    /// 数据放在外圈还是内圈（源项目的「文件区」约定）。
    public var dataAtOuterRing: Bool
    public var volumeLabel: String
    /// DVD 的螺旋方向是顺时针（源项目约定），CD/BD 用 false。
    public var clockwise: Bool
    /// 输出文件基础路径（不含扩展名）。引擎据此派生旁写文件：CD 的 `.cue`、
    /// BD 的 `-bd-r-image-v1.json`。为 nil 时不写旁写文件（内存/测试模式）。
    public var outputBaseURL: URL?
    /// 取消令牌；引擎在每个阶段边界检查。
    public var cancellation: CancellationFlag

    public init(
        geometry: DiscGeometry,
        tone: ToneProfile = .default,
        image: RasterImage,
        outputFormat: GenerationOutputFormat = .iso,
        dataDirectory: URL? = nil,
        dataAtOuterRing: Bool = false,
        volumeLabel: String = "DISC_IMAGE",
        clockwise: Bool = false,
        outputBaseURL: URL? = nil,
        cancellation: CancellationFlag = CancellationFlag()
    ) {
        self.geometry = geometry
        self.tone = tone
        self.image = image
        self.outputFormat = outputFormat
        self.dataDirectory = dataDirectory
        self.dataAtOuterRing = dataAtOuterRing
        self.volumeLabel = volumeLabel
        self.clockwise = clockwise
        self.outputBaseURL = outputBaseURL
        self.cancellation = cancellation
    }
}

/// 生成结果。
public struct GenerationResult: Sendable, Equatable {
    public var byteCount: Int64
    public var summary: String
    /// 中间产物（例如 sidecar JSON、.cue 文件）路径，供 UI 展示。
    public var sidecarURLs: [URL]

    public init(byteCount: Int64, summary: String, sidecarURLs: [URL] = []) {
        self.byteCount = byteCount
        self.summary = summary
        self.sidecarURLs = sidecarURLs
    }
}

/// 每个介质引擎都实现这个协议；`DiscImageCLI` 按 `family` 分发。
public protocol DiscImageGenerator: Sendable {
    var family: DiscFamily { get }
    /// 是否需要 16 扇区 / 32 扇区对齐（由几何校验保证）。
    var sectorAlignment: Int { get }
    func generate(
        _ request: GenerationRequest,
        to sink: SequentialSink,
        progress: @Sendable (DiscProgress) -> Void
    ) throws -> GenerationResult
}

public extension DiscImageGenerator {
    var sectorAlignment: Int {
        switch family {
        case .cd: return 1
        case .dvd: return DiscGeometry.dvdSectorsPerBlock
        case .bluRay: return DiscGeometry.bluRaySectorsPerCluster
        }
    }
}

/// 共享的进度节流器：引擎每写几十万个字节才回调一次，别让 UI 被淹没。
public final class ProgressThrottle: @unchecked Sendable {
    private let report: @Sendable (DiscProgress) -> Void
    private let lock = NSLock()
    private var lastFraction: Double = -.infinity
    private let minimumStep: Double

    public init(minimumStep: Double = 0.01, report: @escaping @Sendable (DiscProgress) -> Void) {
        self.minimumStep = minimumStep
        self.report = report
    }

    public func emit(stage: String, message: String, fraction: Double) {
        lock.lock()
        let shouldEmit = fraction >= 1.0 || fraction - lastFraction >= minimumStep
        if shouldEmit { lastFraction = fraction }
        lock.unlock()
        if shouldEmit {
            report(DiscProgress(stage: stage, message: message, fraction: min(max(fraction, 0), 1)))
        }
    }
}
