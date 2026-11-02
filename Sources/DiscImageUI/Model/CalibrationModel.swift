import DiscImageCore
import Foundation

/// 标定闭环的状态机：生成标定盘 → 照片矫正 → 单曲线描点 → 反推 → 应用。
///
/// 几何/引擎全部来自 `DiscImageCore.Calibration`，这里只负责：
/// - 维护「当前标定盘快照 + 照片 + 控制点 + 曲线点」的可编辑状态；
/// - 在输入变化时正确失效（改边界/改盘片规格 → 矫正与拟合全部作废）；
/// - 把拟合候选、预测叠线、偏差与离群点整理成界面直接可用的值。
///
/// 坐标系约定（与 Core 一致）：
/// - 照片控制点：照片像素，原点左上角，y 向下；
/// - 曲线点 / 预测线：盘面毫米，原点盘心，x 向右、y 向下。
@MainActor
public final class CalibrationModel: ObservableObject {
    public enum BoundaryKind: String, CaseIterable, Sendable {
        case outer
        case hole

        public var displayNameZH: String {
            switch self {
            case .outer: return "实体外缘"
            case .hole: return "中心孔边缘"
            }
        }
    }

    /// 标定的两个步骤。
    public enum Step: String, CaseIterable, Sendable, Identifiable {
        case photo
        case trace

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .photo: return "第一步 · 照片矫正"
            case .trace: return "第二步 · 单条曲线标定"
            }
        }
    }

    /// 矫正画布尺寸（盘面 mm → 像素）。
    public static let rectifiedPixelSize = 800
    public static let patternFileName = "calibration-pattern.png"
    public static let sessionFileName = "calibration.calibration.json"
    /// 生成图案的标准尺寸（Core 输出固定 2400 × 2400）。
    public static let patternPixelSize = CalibrationPattern.pixelSize

    // MARK: - 生成快照 / 记录

    @Published public private(set) var generation: CalibrationGenerationSnapshot?
    @Published public private(set) var patternImage: RasterImage?
    @Published public private(set) var generatedPatternURL: URL?
    @Published public private(set) var sessionPath: URL?

    // MARK: - 照片矫正

    @Published public private(set) var photoImage: RasterImage?
    @Published public private(set) var photoPngBase64: String?
    @Published public private(set) var outerBoundary: [CalibrationPoint] = []
    @Published public private(set) var holeBoundary: [CalibrationPoint] = []
    @Published public private(set) var discSize: CalibrationDiscSize = .standard12cm
    @Published public private(set) var rectification: CalibrationPhotoRectifier.Result?
    @Published public private(set) var rectifiedImage: RasterImage?
    @Published public private(set) var rectificationConfirmed = false
    @Published public var step: Step = .photo {
        didSet {
            if step != oldValue {
                errorMessage = nil
            }
        }
    }

    // MARK: - 曲线反推

    @Published public var fitDvdPitch = true {
        didSet {
            if fitDvdPitch != oldValue { invalidateFit(message: "拟合选项已修改，请重新反推参数。") }
        }
    }
    @Published public private(set) var tracePoints: [CalibrationPoint] = []
    @Published public private(set) var selectedTraceIndex: Int?
    @Published public private(set) var fitResult: CalibrationFitResult?
    @Published public private(set) var selectedCandidateIndex: Int?
    @Published public private(set) var predictionOutline: [CalibrationPoint] = []
    @Published public private(set) var pointDistances: [Double] = []

    @Published public private(set) var statusMessage = "先导入一张实拍照片；也可以打开已有的标定记录继续。"
    @Published public var errorMessage: String?

    public init() {}

    // MARK: - 派生状态

    public var hasPhoto: Bool { photoImage != nil }

    /// 矫正画布半径（mm）：实体外缘 + 3 mm 留边。
    public var photoCanvasOuterRadiusMm: Double { discSize.physicalOuterRadiusMm + 3 }

    public var canRectify: Bool {
        photoImage != nil && outerBoundary.count >= 5 && holeBoundary.count >= 5
    }

    public var canConfirmRectification: Bool { rectification != nil && !rectificationConfirmed }

    public var canFit: Bool { rectificationConfirmed && !tracePoints.isEmpty }

    public var canSaveSession: Bool { generation != nil }

    public var candidates: [CalibrationFitCandidate] { fitResult?.candidates ?? [] }

    public var selectedCandidate: CalibrationFitCandidate? {
        guard let fitResult, let index = selectedCandidateIndex,
              fitResult.candidates.indices.contains(index) else { return nil }
        return fitResult.candidates[index]
    }

    /// 「应用标定参数」按钮的可用条件：候选必须 `isApplicable`，且矫正已确认。
    public func canApply(_ candidate: CalibrationFitCandidate?) -> Bool {
        guard rectificationConfirmed, !tracePoints.isEmpty,
              fitResult?.succeeded == true, let candidate else { return false }
        return candidate.isApplicable
    }

    public var canApplySelectedCandidate: Bool { canApply(selectedCandidate) }

    /// 不能应用时的中文原因（状态行/提示用）。
    public var selectedCandidateRejectionReason: String? {
        guard let fitResult else { return "还没有反推结果。" }
        if !fitResult.succeeded { return fitResult.warnings.first }
        guard let candidate = selectedCandidate else { return "没有可用的候选。" }
        if !candidate.isApplicable {
            return fitResult.rejectionReason ?? "候选偏差过大，不能应用。"
        }
        if !rectificationConfirmed { return "请先确认照片矫正。" }
        return nil
    }

    public var outlierThresholdMm: Double {
        max(0.2, (selectedCandidate?.rmsErrorMm ?? 0) * 2.5)
    }

    /// 与预测曲线偏差超过阈值的曲线点（界面标红）。
    public var outlierIndices: [Int] {
        let threshold = outlierThresholdMm
        return pointDistances.enumerated()
            .filter { $0.element.isFinite && $0.element > threshold }
            .map(\.offset)
    }

    public var traceSummary: String {
        if tracePoints.isEmpty { return "还没有曲线点" }
        return "已保留 \(tracePoints.count) 点 · 偏离点自动标红"
    }

    /// 状态行：平均/最大偏差、搜索范围、离群点。
    public var fitAssessment: String {
        guard let fitResult else {
            return "全部有效点都会参与计算，结果需与实拍曲线核对。"
        }
        guard fitResult.succeeded else {
            return fitResult.warnings.first ?? "计算未通过，全部点已保留。"
        }
        guard let candidate = selectedCandidate else {
            return "没有可应用的候选。"
        }
        var lines: [String] = []
        let accepted = candidate.isApplicable
        lines.append(accepted
            ? String(format: "候选 · 平均偏差 %.3f mm · 最大 %.3f mm", candidate.rmsErrorMm, candidate.maxErrorMm)
            : String(format: "未通过 · 平均偏差 %.3f mm · 最大 %.3f mm，不能应用", candidate.rmsErrorMm, candidate.maxErrorMm))
        if let range = fitResult.searchRangeMm, range.1 > 0.0201 {
            lines.append(String(format: "搜索范围已自动扩大至 ±%.3f mm。", range.1))
        }
        if fitResult.boundaryLimited {
            lines.append("最优解贴近搜索边界，请补点或检查点位。")
        }
        if !outlierIndices.isEmpty {
            lines.append("已标记 \(outlierIndices.count) 个偏离较大的点。")
        }
        if candidate.outlierCount > 0 {
            lines.append("拟合计入 \(candidate.outlierCount) 个离群点（已降权）。")
        }
        return lines.joined(separator: "\n")
    }

    /// 当前工程几何 + 已应用的候选是否已经不是同一组参数。
    public func candidateChangesGeometry(_ candidate: CalibrationFitCandidate, from geometry: DiscGeometry) -> Bool {
        candidate.applying(to: geometry) != geometry
    }

    // MARK: - 生成标定盘

    /// 生成图案 PNG + `.calibration.json`，并固定本次生成快照。
    ///
    /// 生成后会清空上一张标定盘的照片与曲线（与上游语义一致：一张盘对应一份记录）。
    @discardableResult
    public func generatePattern(
        project: DiscProject,
        outputDirectory: URL
    ) throws -> (patternURL: URL, sessionURL: URL) {
        try project.validate()
        let snapshot = CalibrationGenerationSnapshot(
            geometry: project.geometry,
            tone: project.effectiveTone,
            drawingStartSector: 0,
            drawingEndSectorExclusive: 0,
            cdInterleave: project.discFamily == .cd
        )
        try snapshot.validate()
        let image = try CalibrationPattern.image(generation: snapshot)

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let patternURL = outputDirectory.appendingPathComponent(Self.patternFileName)
        let sessionURL = outputDirectory.appendingPathComponent(Self.sessionFileName)
        try image.writePNG(to: patternURL)

        let session = CalibrationSession(generation: snapshot, fitOptions: makeFitOptions())
        try CalibrationSessionStore.save(session, to: sessionURL)

        generation = snapshot
        patternImage = image
        generatedPatternURL = patternURL
        sessionPath = sessionURL
        resetPhotoAndTrace()
        statusMessage = "已生成 2400×2400 标定图案与记录。刻录这张图案后拍照，回到第一步拖边界。"
        errorMessage = nil
        return (patternURL, sessionURL)
    }

    /// 按需加载（或重新渲染）当前快照的图案预览。
    @discardableResult
    public func loadPatternImageIfNeeded() throws -> RasterImage? {
        if let patternImage { return patternImage }
        guard let generation else { return nil }
        let image = try CalibrationPattern.image(generation: generation)
        patternImage = image
        return image
    }

    public func exportPatternPNG(to url: URL) throws {
        guard let generation else {
            throw DiscError.missingPayload("还没有标定生成快照，请先生成标定盘。")
        }
        let image = try patternImage ?? CalibrationPattern.image(generation: generation)
        try image.writePNG(to: url)
        statusMessage = "已导出标定图案：\(url.lastPathComponent)"
    }

    // MARK: - 第一步：照片矫正

    /// 导入照片（按 EXIF 方向摆正、缩到 1600 px 并内嵌 PNG）。
    public func importPhoto(from url: URL) throws {
        let image = try CalibrationPhotoLoader.load(contentsOf: url)
        try importPhoto(image)
    }

    public func importPhoto(_ image: RasterImage) throws {
        let scaled = image.scaled(maxDimension: CalibrationPhotoSession.maximumImageDimension)
        let data = try scaled.pngData()
        resetPhotoAndTrace()
        photoImage = scaled
        photoPngBase64 = data.base64EncodedString()
        (outerBoundary, holeBoundary) = Self.defaultBoundaries(for: scaled)
        discSize = .standard12cm
        step = .photo
        statusMessage = "照片已导入。把两组控制点拖到「实体外缘」和「中心孔边缘」，然后计算矫正。"
        errorMessage = nil
    }

    public func moveBoundaryPoint(_ kind: BoundaryKind, index: Int, to point: CalibrationPoint) {
        guard let image = photoImage,
              point.xMm.isFinite, point.yMm.isFinite else { return }
        let width = Double(image.width - 1)
        let height = Double(image.height - 1)
        let clamped = CalibrationPoint(
            xMm: min(max(point.xMm, 0), max(width, 0)),
            yMm: min(max(point.yMm, 0), max(height, 0))
        )
        switch kind {
        case .outer:
            guard outerBoundary.indices.contains(index) else { return }
            outerBoundary[index] = clamped
        case .hole:
            guard holeBoundary.indices.contains(index) else { return }
            holeBoundary[index] = clamped
        }
        invalidateRectification(clearTrace: true)
        statusMessage = "轮廓已修改，请重新计算矫正。"
    }

    public func setDiscSize(_ size: CalibrationDiscSize) {
        guard size != discSize else { return }
        discSize = size
        invalidateRectification(clearTrace: true)
        statusMessage = "盘片规格已改为 \(size.displayNameZH)，请重新计算矫正。"
    }

    /// 联合拟合两条实体轮廓，生成正视预览。
    public func rectify() throws {
        guard let image = photoImage else {
            throw DiscError.missingPayload("请先导入盘片照片。")
        }
        do {
            let result = try CalibrationPhotoRectifier.fitDetailed(
                outerEdge: outerBoundary,
                centerHole: holeBoundary,
                discSize: discSize
            )
            guard result.transform.isValidForDisc(photoCanvasOuterRadiusMm) else {
                throw DiscError.invalidGeometry("照片变换在当前画布内退化，请重新拖边界或换一张照片。")
            }
            let rectified = try CalibrationRectifiedRenderer.render(
                photo: image,
                transform: result.transform,
                canvasOuterRadiusMm: photoCanvasOuterRadiusMm,
                pixelSize: Self.rectifiedPixelSize
            )
            rectification = result
            rectifiedImage = rectified
            rectificationConfirmed = false
            step = .photo
            statusMessage = "矫正预览已生成。检查盘面恢复正视后，点「确认矫正，开始描线」。"
            errorMessage = nil
        } catch {
            rectification = nil
            rectifiedImage = nil
            rectificationConfirmed = false
            errorMessage = StudioModel.message(for: error)
            statusMessage = "照片矫正失败：\(errorMessage ?? "")"
            throw error
        }
    }

    public func confirmRectification() {
        guard rectification != nil, rectifiedImage != nil else { return }
        rectificationConfirmed = true
        step = .trace
        statusMessage = "矫正已确认。沿一条清楚的径向曲线，从内向外均匀打点（建议 16 点以上）。"
        errorMessage = nil
    }

    /// 返回修正照片：撤销矫正预览、确认与拟合，保留照片和边界。
    public func backToPhoto() {
        rectification = nil
        rectifiedImage = nil
        rectificationConfirmed = false
        step = .photo
        tracePoints = []
        selectedTraceIndex = nil
        invalidateFit(message: "已返回第一步；修正轮廓后重新计算矫正。")
        statusMessage = "已返回照片修正。拖动边界后重新计算矫正。"
    }

    // MARK: - 第二步：曲线描点

    public func addTracePoint(_ point: CalibrationPoint) {
        guard rectificationConfirmed else { return }
        guard point.xMm.isFinite, point.yMm.isFinite else { return }
        let radius = point.radiusMm
        guard radius >= CalibrationDiscSize.standard12cm.physicalHoleRadiusMm - 0.5,
              radius <= discSize.physicalOuterRadiusMm + 0.01 else {
            errorMessage = "曲线点必须落在实体盘面内（7.5–\(Int(discSize.physicalOuterRadiusMm)) mm）。"
            return
        }
        // 点在已有点附近时视为选中，避免把点击当成重复加点。
        if let nearest = nearestTraceIndex(to: point), tracePoints[nearest].distance(to: point) < 1.2 {
            selectedTraceIndex = nearest
            return
        }
        tracePoints.append(point)
        tracePoints.sort { $0.radiusMm < $1.radiusMm }
        selectedTraceIndex = nearestTraceIndex(to: point)
        invalidateFit(message: "曲线已修改，请重新反推参数。")
        errorMessage = nil
    }

    public func moveTracePoint(at index: Int, to point: CalibrationPoint) {
        guard tracePoints.indices.contains(index), point.xMm.isFinite, point.yMm.isFinite else { return }
        let radius = point.radiusMm
        guard radius >= CalibrationDiscSize.standard12cm.physicalHoleRadiusMm - 0.5,
              radius <= discSize.physicalOuterRadiusMm + 0.01 else { return }
        tracePoints[index] = point
        tracePoints.sort { $0.radiusMm < $1.radiusMm }
        selectedTraceIndex = nearestTraceIndex(to: point)
        invalidateFit(message: "曲线已修改，请重新反推参数。")
    }

    public func selectTracePoint(at index: Int?) {
        guard let index, tracePoints.indices.contains(index) else {
            selectedTraceIndex = nil
            return
        }
        selectedTraceIndex = index
    }

    public func removeTracePoint(at index: Int) {
        guard tracePoints.indices.contains(index) else { return }
        tracePoints.remove(at: index)
        selectedTraceIndex = tracePoints.isEmpty ? nil : min(index, tracePoints.count - 1)
        invalidateFit(message: "曲线已修改，请重新反推参数。")
    }

    public func removeSelectedTracePoint() {
        guard let index = selectedTraceIndex else { return }
        removeTracePoint(at: index)
    }

    public func clearTrace() {
        tracePoints = []
        selectedTraceIndex = nil
        invalidateFit(message: "曲线已清空。")
    }

    // MARK: - 反推

    /// 用当前曲线反推参数。输入不足时 Core 会返回 `succeeded == false` 的结果而不是抛错。
    public func fit() {
        guard rectificationConfirmed else {
            errorMessage = "请先确认照片矫正。"
            return
        }
        do {
            let session = try makeSession()
            let result = try CalibrationCrossFitter.fit(
                session: session,
                points: tracePoints,
                options: makeFitOptions()
            )
            fitResult = result
            if result.succeeded, !result.candidates.isEmpty {
                selectedCandidateIndex = 0
                refreshPrediction()
                if let candidate = selectedCandidate, !candidate.isApplicable {
                    statusMessage = result.rejectionReason ?? "候选偏差较大，暂时不能应用。"
                } else {
                    statusMessage = "已用全部 \(tracePoints.count) 点生成 \(result.candidates.count) 个候选；请核对橙色预测叠线。"
                }
            } else {
                selectedCandidateIndex = nil
                predictionOutline = []
                pointDistances = []
                statusMessage = result.warnings.first ?? "计算未通过，全部曲线点已保留。"
            }
            errorMessage = nil
        } catch {
            fitResult = nil
            selectedCandidateIndex = nil
            predictionOutline = []
            pointDistances = []
            errorMessage = StudioModel.message(for: error)
            statusMessage = "反推失败：\(errorMessage ?? "")"
        }
    }

    public func selectCandidate(at index: Int) {
        guard candidates.indices.contains(index) else { return }
        selectedCandidateIndex = index
        refreshPrediction()
    }

    // MARK: - 会话

    /// 由当前状态组装标定记录（保存前会完整校验）。
    public func makeSession() throws -> CalibrationSession {
        guard let generation else {
            throw DiscError.missingPayload("还没有标定生成快照，请先生成标定盘或打开标定记录。")
        }
        var photo: CalibrationPhotoSession?
        if let png = photoPngBase64 {
            let traces: [CalibrationCrossTrace] = (rectificationConfirmed && !tracePoints.isEmpty)
                ? [CalibrationCrossTrace(armIndex: 0, points: tracePoints)]
                : []
            photo = CalibrationPhotoSession(
                imagePngBase64: png,
                outerBoundary: outerBoundary,
                holeBoundary: holeBoundary,
                physicalOuterRadiusMm: discSize.physicalOuterRadiusMm,
                rectificationConfirmed: rectificationConfirmed,
                traces: traces
            )
        }
        let session = CalibrationSession(generation: generation, photo: photo, fitOptions: makeFitOptions())
        try session.validate()
        return session
    }

    public func saveSession(to url: URL) throws {
        let session = try makeSession()
        try CalibrationSessionStore.save(session, to: url)
        sessionPath = url
        statusMessage = "标定记录已保存：\(url.lastPathComponent)（候选不持久化，可重新反推）。"
        errorMessage = nil
    }

    public func openSession(from url: URL) throws {
        let session = try CalibrationSessionStore.load(from: url)
        try loadSession(session)
        sessionPath = url
    }

    /// 恢复一份会话：照片、边界、盘片规格与曲线点；候选不恢复。
    public func loadSession(_ session: CalibrationSession) throws {
        try session.validate()
        generation = session.generation
        patternImage = nil
        generatedPatternURL = nil
        photoImage = nil
        photoPngBase64 = nil
        outerBoundary = []
        holeBoundary = []
        rectification = nil
        rectifiedImage = nil
        rectificationConfirmed = false
        tracePoints = []
        selectedTraceIndex = nil
        fitResult = nil
        selectedCandidateIndex = nil
        predictionOutline = []
        pointDistances = []
        step = .photo

        if let photo = session.photo {
            let image = try photo.decodedImage()
            photoImage = image
            photoPngBase64 = photo.imagePngBase64
            outerBoundary = photo.outerBoundary
            holeBoundary = photo.holeBoundary
            discSize = photo.discSize ?? .standard12cm
            if photo.rectificationConfirmed {
                let result = try CalibrationPhotoRectifier.fitDetailed(
                    outerEdge: photo.outerBoundary,
                    centerHole: photo.holeBoundary,
                    discSize: discSize
                )
                rectifiedImage = try CalibrationRectifiedRenderer.render(
                    photo: image,
                    transform: result.transform,
                    canvasOuterRadiusMm: photoCanvasOuterRadiusMm,
                    pixelSize: Self.rectifiedPixelSize
                )
                rectification = result
                rectificationConfirmed = true
                tracePoints = (photo.traces.first?.points ?? []).sorted { $0.radiusMm < $1.radiusMm }
                selectedTraceIndex = tracePoints.isEmpty ? nil : 0
                step = .trace
            }
        }
        fitDvdPitch = session.fitOptions?.fitDvdPitch ?? fitDvdPitch
        statusMessage = "已恢复标定记录：生成快照、照片、轮廓与曲线点都在；候选需要重新反推。"
        errorMessage = nil
    }

    /// 清空全部标定状态（新建/打开工程时调用）。
    public func reset() {
        generation = nil
        patternImage = nil
        generatedPatternURL = nil
        sessionPath = nil
        resetPhotoAndTrace()
        statusMessage = "先导入一张实拍照片；也可以打开已有的标定记录继续。"
        errorMessage = nil
    }

    // MARK: - 坐标换算（界面绘制用）

    /// 矫正画布像素 → 盘面毫米。
    public func discPoint(canvasX: Double, canvasY: Double, canvasSize: Int) -> CalibrationPoint {
        let mmPerPixel = photoCanvasOuterRadiusMm * 2 / Double(max(canvasSize, 1))
        let centre = Double(canvasSize) / 2
        return CalibrationPoint(
            xMm: (canvasX - centre) * mmPerPixel,
            yMm: (canvasY - centre) * mmPerPixel
        )
    }

    /// 盘面毫米 → 矫正画布像素。
    public func canvasPoint(discPoint: CalibrationPoint, canvasSize: Int) -> CalibrationPoint {
        let mmPerPixel = photoCanvasOuterRadiusMm * 2 / Double(max(canvasSize, 1))
        let centre = Double(canvasSize) / 2
        return CalibrationPoint(
            xMm: centre + discPoint.xMm / mmPerPixel,
            yMm: centre + discPoint.yMm / mmPerPixel
        )
    }

    // MARK: - 内部

    private func makeFitOptions() -> CalibrationFitOptions {
        var options = CalibrationFitOptions.default
        options.fitDvdPitch = fitDvdPitch && (generation?.geometry.family == .dvd)
        options.adaptiveRobustScale = true
        return options
    }

    private func invalidateFit(message: String? = nil) {
        fitResult = nil
        selectedCandidateIndex = nil
        predictionOutline = []
        pointDistances = []
        if let message {
            statusMessage = message
        }
    }

    private func invalidateRectification(clearTrace: Bool) {
        rectification = nil
        rectifiedImage = nil
        rectificationConfirmed = false
        step = .photo
        if clearTrace {
            tracePoints = []
            selectedTraceIndex = nil
        }
        invalidateFit()
    }

    private func resetPhotoAndTrace() {
        photoImage = nil
        photoPngBase64 = nil
        outerBoundary = []
        holeBoundary = []
        rectification = nil
        rectifiedImage = nil
        rectificationConfirmed = false
        tracePoints = []
        selectedTraceIndex = nil
        step = .photo
        invalidateFit()
    }

    private func refreshPrediction() {
        guard let candidate = selectedCandidate, tracePoints.count >= 2 else {
            predictionOutline = []
            pointDistances = []
            return
        }
        do {
            let session = try makeSession()
            let radii = tracePoints.map(\.radiusMm)
            let minimum = radii.min() ?? 0
            let maximum = radii.max() ?? 0
            guard maximum > minimum else { return }
            predictionOutline = try CalibrationCrossPrediction.outline(
                session: session,
                candidate: candidate,
                minimumObservedRadiusMm: minimum,
                maximumObservedRadiusMm: maximum
            )
            pointDistances = try CalibrationCrossPrediction.distances(
                session: session,
                candidate: candidate,
                points: tracePoints
            )
            errorMessage = nil
        } catch {
            predictionOutline = []
            pointDistances = []
            errorMessage = StudioModel.message(for: error)
        }
    }

    private func nearestTraceIndex(to point: CalibrationPoint) -> Int? {
        guard !tracePoints.isEmpty else { return nil }
        var bestIndex = 0
        var bestDistance = Double.infinity
        for (index, candidate) in tracePoints.enumerated() {
            let distance = candidate.distance(to: point)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    /// 初始八点圆：外缘 0.43 × 图像短边，中心孔按真实盘片比例 7.5/60 收缩。
    static func defaultBoundaries(for image: RasterImage) -> (outer: [CalibrationPoint], hole: [CalibrationPoint]) {
        let centreX = Double(image.width - 1) / 2
        let centreY = Double(image.height - 1) / 2
        let radiusX = Double(image.width) * 0.43
        let radiusY = Double(image.height) * 0.43
        func circle(_ ratio: Double) -> [CalibrationPoint] {
            (0..<8).map { index in
                let angle = -.pi / 2 + 2 * .pi * Double(index) / 8
                return CalibrationPoint(
                    xMm: centreX + radiusX * ratio * cos(angle),
                    yMm: centreY + radiusY * ratio * sin(angle)
                )
            }
        }
        return (circle(1), circle(CalibrationDiscSize.standard12cm.physicalHoleRadiusMm
            / CalibrationDiscSize.standard12cm.physicalOuterRadiusMm))
    }
}
