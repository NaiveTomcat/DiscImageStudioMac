import DiscImageBluRay
import DiscImageCd
import DiscImageCore
import DiscImageDvd
import Foundation

/// 生成调度：把工程/设计图变成一个引擎可执行的 `GenerationRequest`，并分派到对应介质。
///
/// 分派集中在本文件（唯一接线点）：工作包 A/B/C 的三类生成器
/// （`DvdImageGenerator` / `CdImageGenerator` / `BluRayImageGenerator`）都已接入，
/// 新增介质或替换实现只需改 `makeDefaultFactory`，UI 其它文件不用动。
public struct GenerationService: Sendable {
    public typealias GeneratorFactory = @Sendable (DiscFamily) throws -> DiscImageGenerator

    private let factory: GeneratorFactory

    public init(factory: @escaping GeneratorFactory = { family in try GenerationService.makeDefaultFactory(family) }) {
        self.factory = factory
    }

    /// **接线点（lead / A、B、C）**：三种介质落地一个就接一个。
    ///
    /// 三种介质的生成器分派（工作包 A/B/C 均已落地）。
    public static func makeDefaultFactory(_ family: DiscFamily) throws -> DiscImageGenerator {
        switch family {
        case .cd:
            return CdImageGenerator()
        case .dvd:
            return DvdImageGenerator()
        case .bluRay:
            return BluRayImageGenerator()
        }
    }

    /// 是否已有可用的引擎（界面用来提前灰掉「开始导出」）。
    public func hasGenerator(for family: DiscFamily) -> Bool {
        (try? factory(family)) != nil
    }

    /// 由工程推导输出文件 URL：`outputPath` 的空缺/扩展名不匹配都在这里修正。
    public static func outputURL(for project: DiscProject, format: GenerationOutputFormat) -> URL {
        var path = project.outputs.outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            path = DiscProject.defaultOutputPath(for: project.name, family: project.discFamily)
        }
        var url = URL(fileURLWithPath: path)
        if url.pathExtension.lowercased() != format.fileExtension {
            url = url.deletingPathExtension().appendingPathExtension(format.fileExtension)
        }
        return url
    }

    /// 构造请求（不执行）。
    public static func makeRequest(
        project: DiscProject,
        tone: ToneProfile,
        image: RasterImage,
        format: GenerationOutputFormat,
        outputURL: URL,
        dataDirectory: URL?,
        cancellation: CancellationFlag
    ) -> GenerationRequest {
        GenerationRequest(
            geometry: project.geometry,
            tone: tone.normalized(),
            image: image,
            outputFormat: format,
            dataDirectory: dataDirectory,
            dataAtOuterRing: project.outputs.filesAtOuterRing,
            volumeLabel: project.outputs.volumeLabel,
            clockwise: project.discFamily == .dvd,
            outputBaseURL: outputURL.deletingPathExtension(),
            cancellation: cancellation
        )
    }

    /// 执行生成并落盘。
    ///
    /// 失败或取消时删掉半个输出文件 —— 生成失败必须留下「没有文件」，
    /// 而不是一个看起来能烧的坏镜像。
    @discardableResult
    public func generate(
        project: DiscProject,
        tone: ToneProfile,
        image: RasterImage,
        format: GenerationOutputFormat,
        outputURL: URL,
        dataDirectory: URL?,
        progress: @escaping @Sendable (DiscProgress) -> Void,
        cancellation: CancellationFlag
    ) throws -> GenerationResult {
        try project.validate()
        try tone.validate()
        guard format.fileExtension == outputURL.pathExtension.lowercased() else {
            throw DiscError.invalidGeometry(
                "输出扩展名与格式不匹配：\(format.displayNameZH) 应为 .\(format.fileExtension)。"
            )
        }
        if dataDirectory != nil, format == .wav {
            throw DiscError.unsupported("CD 音频轨不支持数据目录；数据盘请改用 ISO 格式。")
        }
        let generator = try factory(project.discFamily)
        guard generator.family == project.discFamily else {
            throw DiscError.encoding(
                "引擎介质不匹配：需要 \(project.discFamily.displayNameZH)，实际是 \(generator.family.displayNameZH)。"
            )
        }
        guard generator.sectorAlignment == 1 || project.geometry.sectors % generator.sectorAlignment == 0 else {
            throw DiscError.invalidGeometry(
                "扇区数必须是 \(generator.sectorAlignment) 的整数倍（当前 \(project.geometry.sectors)）。"
            )
        }
        guard !cancellation.isCancelled else { throw CancellationError() }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let request = Self.makeRequest(
            project: project,
            tone: tone,
            image: image,
            format: format,
            outputURL: outputURL,
            dataDirectory: dataDirectory,
            cancellation: cancellation
        )

        let sink = try FileSequentialSink(url: outputURL)
        do {
            let result = try generator.generate(request, to: sink, progress: progress)
            try sink.close()
            try cancellation.check()
            return result
        } catch {
            try? sink.close()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }
}

/// 导出页的作业状态机（UI 与测试共用）。
@MainActor
public final class GenerationJob: ObservableObject {
    public enum State: Equatable {
        case idle
        case running(DiscProgress)
        case succeeded(GenerationResult)
        case failed(String)
        case cancelled

        public var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var outputURL: URL?

    private var cancellation: CancellationFlag?
    private var task: Task<Void, Never>?

    public init() {}

    /// 启动生成。立即返回；状态与进度通过 `@Published` 推给界面。
    ///
    /// `imageProvider` 在后台线程执行（8192 px 合成本身要几秒），
    /// 这样导出的准备工作不会卡住主线程。
    public func start(
        service: GenerationService,
        project: DiscProject,
        tone: ToneProfile,
        imageProvider: @escaping @Sendable () throws -> RasterImage,
        format: GenerationOutputFormat,
        outputURL: URL,
        dataDirectory: URL?
    ) {
        guard !state.isRunning else { return }
        let cancellation = CancellationFlag()
        self.cancellation = cancellation
        self.outputURL = outputURL
        state = .running(DiscProgress(stage: "compose", message: "正在合成 8192 px 设计图…", fraction: 0))

        let job = self
        task = Task.detached(priority: .userInitiated) { [job] in
            do {
                let image = try imageProvider()
                try cancellation.check()
                await MainActor.run {
                    guard job.state.isRunning else { return }
                    job.state = .running(DiscProgress(stage: "engine", message: "已合成，等待引擎…", fraction: 0.02))
                }
                let result = try service.generate(
                    project: project,
                    tone: tone,
                    image: image,
                    format: format,
                    outputURL: outputURL,
                    dataDirectory: dataDirectory,
                    progress: { progress in
                        Task { @MainActor in
                            guard job.state.isRunning else { return }
                            job.state = .running(progress)
                        }
                    },
                    cancellation: cancellation
                )
                await MainActor.run {
                    job.state = .succeeded(result)
                }
            } catch is CancellationError {
                await MainActor.run {
                    job.state = .cancelled
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    job.state = .failed(message)
                }
            }
        }
    }

    public func cancel() {
        cancellation?.cancel()
    }

    public func reset() {
        guard !state.isRunning else { return }
        state = .idle
        outputURL = nil
        cancellation = nil
        task = nil
    }
}
