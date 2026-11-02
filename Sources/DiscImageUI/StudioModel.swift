import DiscImageCore
import Foundation
import SwiftUI

/// 应用状态：工程、页面、最近工程、图层缓存、预览与两个作业状态机。
///
/// 单向依赖：UI 只依赖 `DiscImageCore` 的模型与引擎协议；引擎/刻录通过
/// `GenerationService` 与 `BurnServicing` 注入，方便测试时替换。
@MainActor
public final class StudioModel: ObservableObject {
    /// 六个工作区页面（HANDOFF §6.D）。
    public enum Page: String, CaseIterable, Identifiable, Sendable {
        case home, design, preview, export, burn, calibration

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .home: return "主页"
            case .design: return "设计"
            case .preview: return "预览"
            case .export: return "导出"
            case .burn: return "刻录"
            case .calibration: return "标定"
            }
        }

        public var symbolName: String {
            switch self {
            case .home: return "house"
            case .design: return "paintbrush"
            case .preview: return "circle.circle"
            case .export: return "square.and.arrow.up"
            case .burn: return "opticaldisc"
            case .calibration: return "slider.horizontal.3"
            }
        }

        public var subtitle: String {
            switch self {
            case .home: return "模板与最近工程"
            case .design: return "图层、影调与合成图"
            case .preview: return "盘面极坐标预览"
            case .export: return "生成 ISO / WAV+CUE / RAW"
            case .burn: return "设备、空白检查与刻录"
            case .calibration: return "三次轨距与标定会话"
            }
        }
    }

    // MARK: - 发布状态

    @Published public var page: Page = .home

    /// 当前工程。直接绑定编辑；`didSet` 负责脏标记。
    @Published public var project: DiscProject {
        didSet {
            if project != oldValue {
                isDirty = true
            }
        }
    }

    @Published public private(set) var projectURL: URL?
    @Published public private(set) var isDirty = false
    @Published public private(set) var recentProjects: [RecentProjectEntry] = []
    @Published public var statusMessage: String?
    @Published public var alertMessage: String?

    /// 图层 id → 解码后的图片（合成与画布用）。
    @Published public private(set) var layerImages: [String: RasterImage] = [:]
    /// 图层 id → 载入失败原因（界面上标红）。
    @Published public private(set) var layerLoadErrors: [String: String] = [:]
    @Published public var selectedLayerID: String?

    /// 2048 px 合成图（设计页预览与导出共用）。
    @Published public private(set) var composedPreview: RasterImage?
    /// 盘面极坐标预览（预览页显示）。
    @Published public private(set) var discPreview: RasterImage?
    @Published public var previewMode: DiscPreviewMode = .design {
        didSet {
            if previewMode != oldValue { refreshDiscPreview() }
        }
    }
    @Published public private(set) var previewErrorMessage: String?
    /// 文件区（黄色标记）；数据盘目录为空时为 nil。
    @Published public private(set) var fileRegion: FileRegion?
    /// 标定参数应用后亮起，直到新建/打开工程。界面用它显示「参数已更新」提示。
    @Published public private(set) var calibrationParametersUpdated = false

    public let generationJob = GenerationJob()
    public let burnWorkflow: BurnWorkflow
    /// 标定闭环的状态机（生成图案 → 照片矫正 → 曲线反推 → 应用）。
    public let calibration: CalibrationModel

    private let projectStore: ProjectStore
    private let recentStore: RecentProjectStore
    private let generationService: GenerationService

    // MARK: - 初始化

    public init(
        project: DiscProject? = nil,
        projectURL: URL? = nil,
        projectStore: ProjectStore = ProjectStore(),
        recentStore: RecentProjectStore = RecentProjectStore(),
        generationService: GenerationService = GenerationService(),
        burnService: BurnServicing = BurnServiceProvider.makeDefault(),
        calibration: CalibrationModel? = nil
    ) {
        self.projectStore = projectStore
        self.recentStore = recentStore
        self.generationService = generationService
        self.burnWorkflow = BurnWorkflow(service: burnService)
        self.calibration = calibration ?? CalibrationModel()
        self.project = project ?? DiscProject.makeNew(name: "未命名工程", preset: .cd80)
        self.projectURL = projectURL
        self.recentProjects = recentStore.load()
        reloadLayerImages()
        refreshPreview()
    }

    // MARK: - 便利属性

    public var layers: [DesignLayer] { project.layers }

    public var selectedLayer: DesignLayer? {
        guard let selectedLayerID else { return nil }
        return project.layers.first { $0.id == selectedLayerID }
    }

    public var selectedLayerImage: RasterImage? {
        guard let selectedLayerID else { return nil }
        return layerImages[selectedLayerID]
    }

    public var tone: ToneProfile {
        get { project.effectiveTone }
        set {
            var normalized = newValue.normalized()
            if project.discFamily != .cd, normalized.levels == ToneProfile.fourLevels {
                normalized.levels = ToneProfile.twoLevels
            }
            project.tone = normalized
        }
    }

    /// 影调面板的绑定。
    public var toneBinding: Binding<ToneProfile> {
        Binding(get: { self.tone }, set: { self.tone = $0 })
    }

    public var displayTitle: String {
        let suffix = isDirty ? " • 已修改" : ""
        return "\(project.name)\(suffix)"
    }

    public var canExport: Bool {
        generationService.hasGenerator(for: project.discFamily)
    }

    public var engineUnavailableReason: String? {
        guard !canExport else { return nil }
        return "\(project.discFamily.displayNameZH) 生成引擎当前不可用，请检查构建是否完整。"
    }

    // MARK: - 页面

    public func navigate(to page: Page) {
        self.page = page
        switch page {
        case .preview:
            refreshDiscPreview()
        case .export:
            if fileRegion == nil { refreshFileRegion() }
        case .burn:
            if burnWorkflow.devices.isEmpty, !burnWorkflow.phase.isBusy {
                burnWorkflow.refreshDevices()
            }
        case .home:
            recentProjects = recentStore.load()
        case .design, .calibration:
            break
        }
    }

    // MARK: - 工程生命周期

    /// 新建工程（主页模板）。
    public func newProject(preset: DiscPreset, name: String? = nil, now: Date = Date()) {
        let resolvedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectName = (resolvedName?.isEmpty == false) ? resolvedName! : "\(preset.family.displayNameZH) 新工程"
        project = DiscProject.makeNew(name: projectName, preset: preset, now: now)
        projectURL = nil
        isDirty = false
        selectedLayerID = nil
        layerImages = [:]
        layerLoadErrors = [:]
        calibration.reset()
        calibrationParametersUpdated = false
        page = .design
        refreshPreview()
        statusMessage = "已创建「\(projectName)」（\(preset.displayName)）"
    }

    public func openProject(at url: URL) throws {
        let loaded = try projectStore.load(from: url)
        project = loaded
        projectURL = url
        isDirty = false
        selectedLayerID = loaded.layers.first?.id
        reloadLayerImages()
        refreshPreview()
        recentProjects = recentStore.record(RecentProjectEntry(project: loaded, path: url))
        calibrationParametersUpdated = false
        calibration.reset()
        if let sessionPath = loaded.calibrationSessionPath,
           FileManager.default.fileExists(atPath: sessionPath) {
            do {
                try calibration.openSession(from: URL(fileURLWithPath: sessionPath))
            } catch {
                alertMessage = "工程关联的标定记录无法加载：\(Self.message(for: error))"
            }
        }
        page = .design
        statusMessage = "已打开「\(loaded.name)」"
    }

    /// 打开最近工程；文件缺失时给出明确提示。
    public func openRecent(_ entry: RecentProjectEntry) {
        guard entry.fileExists else {
            alertMessage = "工程文件已移动或删除：\(entry.projectPath)"
            recentProjects = recentStore.remove(projectPath: entry.projectPath)
            return
        }
        do {
            try openProject(at: entry.projectURL)
        } catch {
            alertMessage = Self.message(for: error)
        }
    }

    @discardableResult
    public func saveProject(to url: URL) throws -> DiscProject {
        var document = project
        document.thumbnailPngBase64 = (try? DesignComposer.thumbnailBase64(
            project: document,
            layerImages: layerImages
        )) ?? document.thumbnailPngBase64
        let saved = try projectStore.save(document, to: url)
        project = saved
        projectURL = url
        isDirty = false
        recentProjects = recentStore.record(RecentProjectEntry(project: saved, path: url))
        statusMessage = "已保存「\(url.lastPathComponent)」"
        return saved
    }

    /// 保存到当前路径；没有路径时抛出（由界面弹保存面板）。
    @discardableResult
    public func saveProjectInPlace() throws -> DiscProject {
        guard let projectURL else {
            throw DiscError.io("工程还没有保存路径，请使用「另存为」。")
        }
        return try saveProject(to: projectURL)
    }

    public func closeProject() {
        project = DiscProject.makeNew(name: "未命名工程", preset: .cd80)
        projectURL = nil
        isDirty = false
        selectedLayerID = nil
        layerImages = [:]
        layerLoadErrors = [:]
        calibration.reset()
        calibrationParametersUpdated = false
        page = .home
        refreshPreview()
    }

    // MARK: - 图层

    /// 导入图片作为新图层（放在最上层）。
    @discardableResult
    public func addLayer(imageURL: URL) throws -> DesignLayer {
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            throw DiscError.io("找不到图片：\(imageURL.lastPathComponent)")
        }
        let raster = try DesignComposer.loadLayerImage(at: imageURL)
        // 同名图层自动编号，避免列表里分不清。
        let baseName = imageURL.deletingPathExtension().lastPathComponent
        var name = baseName
        var counter = 2
        while project.layers.contains(where: { $0.name == name }) {
            name = "\(baseName) \(counter)"
            counter += 1
        }
        let layer = DesignLayer(name: name, imagePath: imageURL.path)
        project.layers.insert(layer, at: 0)
        layerImages[layer.id] = raster
        layerLoadErrors[layer.id] = nil
        selectedLayerID = layer.id
        refreshPreview()
        return layer
    }

    public func removeLayer(id: String) {
        project.layers.removeAll { $0.id == id }
        layerImages[id] = nil
        layerLoadErrors[id] = nil
        if selectedLayerID == id {
            selectedLayerID = project.layers.first?.id
        }
        refreshPreview()
    }

    /// 调整图层顺序（0 = 最上层）。
    public func moveLayer(id: String, to newIndex: Int) {
        guard let current = project.layers.firstIndex(where: { $0.id == id }) else { return }
        let layer = project.layers.remove(at: current)
        let clamped = min(max(newIndex, 0), project.layers.count)
        project.layers.insert(layer, at: clamped)
        refreshPreview()
    }

    public func selectLayer(id: String?) {
        selectedLayerID = id
    }

    /// 重新解码全部图层（打开工程/路径变化后调用）。
    public func reloadLayerImages() {
        var images: [String: RasterImage] = [:]
        var errors: [String: String] = [:]
        for layer in project.layers {
            do {
                images[layer.id] = try DesignComposer.loadLayerImage(at: layer.imageURL)
            } catch {
                errors[layer.id] = Self.message(for: error)
            }
        }
        layerImages = images
        layerLoadErrors = errors
        if selectedLayerID == nil || !project.layers.contains(where: { $0.id == selectedLayerID }) {
            selectedLayerID = project.layers.first?.id
        }
    }

    // MARK: - 影调 / 几何 / 标定

    public func setTone(_ tone: ToneProfile) {
        var normalized = tone.normalized()
        if project.discFamily != .cd, normalized.levels == ToneProfile.fourLevels {
            normalized.levels = ToneProfile.twoLevels
        }
        project.tone = normalized
        refreshDiscPreview()
    }

    /// 记录/清除工程关联的标定会话路径（生成图案、保存标定记录时调用）。
    public func recordCalibrationSession(path: URL?) {
        let trimmed = path?.path.trimmingCharacters(in: .whitespacesAndNewlines)
        project.calibrationSessionPath = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// 标定第二步「应用标定参数」：候选写回当前工程几何，并亮起「参数已更新」提示。
    ///
    /// 只更新内外半径与 DVD 三次轨距系数（`CalibrationFitCandidate.applying(to:)` 的语义）；
    /// 扇区数、BD 极性等由生成快照决定，不在这一步改。
    public func applyCalibrationCandidate(
        _ candidate: CalibrationFitCandidate,
        sessionPath: URL? = nil
    ) throws {
        guard candidate.isApplicable else {
            throw DiscError.unsupported("候选偏差过大，不能应用；请修正标红点或补点后重新反推。")
        }
        try applyCalibrationGeometry(candidate.applying(to: project.geometry), sessionPath: sessionPath)
    }

    /// 把一组标定后的几何写回工程（内部校验 + 刷新预览 + 参数已更新提示）。
    public func applyCalibrationGeometry(
        _ geometry: DiscGeometry,
        sessionPath: URL? = nil
    ) throws {
        guard geometry.family == project.discFamily else {
            throw DiscError.invalidGeometry(
                "标定几何的介质（\(geometry.family.displayNameZH)）与工程（\(project.discFamily.displayNameZH)）不一致。"
            )
        }
        var updated = project
        updated.geometry = geometry
        if let sessionPath {
            updated.calibrationSessionPath = sessionPath.path
        }
        try updated.validate()
        project = updated
        calibrationParametersUpdated = true
        refreshPreview()
        statusMessage = "标定参数已更新：内 \(String(format: "%.4f", geometry.innerRadiusMm)) mm / 外 \(String(format: "%.4f", geometry.outerRadiusMm)) mm"
    }

    /// 手工覆盖标定参数（旧版占位入口，保留给命令行/回归用例）。
    public func applyCalibration(
        sessionPath: String?,
        pitchLinear: Double,
        pitchQuadratic: Double,
        pitchCubic: Double,
        invertMapping: Bool
    ) throws {
        var updated = project
        updated.calibrationSessionPath = sessionPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            ? nil
            : sessionPath
        updated.geometry.pitchLinear = project.discFamily == .bluRay ? 0 : pitchLinear
        updated.geometry.pitchQuadratic = project.discFamily == .bluRay ? 0 : pitchQuadratic
        updated.geometry.pitchCubic = project.discFamily == .bluRay ? 0 : pitchCubic
        if project.discFamily == .bluRay {
            updated.bluRay = BluRaySettings(invertMapping: invertMapping)
        }
        try updated.validate()
        project = updated
        calibrationParametersUpdated = true
        refreshDiscPreview()
        statusMessage = "标定参数已写入工程"
    }

    public func setOutputFormat(_ format: GenerationOutputFormat) {
        var updated = project
        let current = GenerationService.outputURL(for: project, format: project.outputFormat)
        let newURL = current.deletingPathExtension().appendingPathExtension(format.fileExtension)
        updated.outputs.outputPath = newURL.path
        project = updated
    }

    // MARK: - 合成与预览

    /// 重新合成 2048 px 设计图，并刷新盘面预览与文件区。
    public func refreshPreview() {
        let layers = project.layers
        let images = layerImages
        let radius = project.canvasOuterRadiusMm
        do {
            composedPreview = try DesignComposer.compose(
                layers: layers,
                layerImages: images,
                canvasOuterRadiusMm: radius,
                outputSize: DesignComposer.previewSize
            )
            previewErrorMessage = nil
        } catch {
            composedPreview = nil
            previewErrorMessage = Self.message(for: error)
        }
        refreshFileRegion()
        refreshDiscPreview()
    }

    /// 只重算盘面预览（模式切换、文件区变化时用）。
    public func refreshDiscPreview() {
        do {
            discPreview = try DiscPreviewRenderer.render(
                project: project,
                sourceImage: composedPreview,
                fileRegion: fileRegion,
                outputSize: 1024,
                mode: previewMode
            )
            if previewErrorMessage == nil {
                previewErrorMessage = nil
            }
        } catch {
            discPreview = nil
            previewErrorMessage = Self.message(for: error)
        }
    }

    /// 由数据盘目录粗估文件区（黄色标记）。
    public func refreshFileRegion() {
        guard project.outputs.hasDataDirectory else {
            fileRegion = nil
            return
        }
        let url = URL(fileURLWithPath: project.outputs.dataDirectory)
        guard let entries = try? FileTree.scan(root: url) else {
            fileRegion = nil
            return
        }
        fileRegion = FileRegion.estimated(
            dataByteCount: FileTree.totalBytes(entries),
            geometry: project.geometry,
            atOuterRing: project.outputs.filesAtOuterRing
        )
    }

    /// 合成图导出（设计页按钮：8192 px）。
    public func exportComposite(to url: URL, size: Int = DesignComposer.exportSize) throws -> RasterImage {
        let image = try DesignComposer.writeCompositePNG(
            project: project,
            layerImages: layerImages,
            outputSize: size,
            to: url
        )
        statusMessage = "已导出合成图 \(size)×\(size)：\(url.lastPathComponent)"
        return image
    }

    /// 盘面预览导出（预览页按钮：2048 px）。
    public func exportDiscPreview(to url: URL, size: Int = DesignComposer.previewSize) throws {
        let image = try DiscPreviewRenderer.render(
            project: project,
            sourceImage: composedPreview,
            fileRegion: fileRegion,
            outputSize: size,
            mode: previewMode
        )
        try image.writePNG(to: url)
        statusMessage = "已导出盘面预览 \(size)×\(size)：\(url.lastPathComponent)"
    }

    // MARK: - 导出（生成）

    /// 导出页「开始生成」：合成 8192 px 后交给引擎，进度与取消由 `generationJob` 管。
    public func startGeneration(format: GenerationOutputFormat, outputURL: URL) {
        project.outputs.outputPath = outputURL.path
        let project = project
        let images = layerImages
        let tone = project.effectiveTone
        let dataDirectory = project.outputs.hasDataDirectory
            ? URL(fileURLWithPath: project.outputs.dataDirectory)
            : nil
        let canvasRadius = project.canvasOuterRadiusMm
        let layers = project.layers

        generationJob.start(
            service: generationService,
            project: project,
            tone: tone,
            imageProvider: {
                try DesignComposer.compose(
                    layers: layers,
                    layerImages: images,
                    canvasOuterRadiusMm: canvasRadius,
                    outputSize: DesignComposer.exportSize
                )
            },
            format: format,
            outputURL: outputURL,
            dataDirectory: dataDirectory
        )
    }

    public func cancelGeneration() {
        generationJob.cancel()
    }

    // MARK: - 错误文案

    public static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
