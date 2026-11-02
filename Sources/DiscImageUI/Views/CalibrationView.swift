import DiscImageCore
import SwiftUI
import UniformTypeIdentifiers

/// 标定页：生成标定盘 → 照片矫正 → 单曲线描点 → 反推 → 应用。
///
/// 界面语义对照上游 `docs/CALIBRATION.md`：三步在同一页里，左边是照片/盘面舞台，
/// 右边是检查器；输入一旦变化（拖控制点、改盘片规格、改曲线点），旧的矫正与拟合
/// 都会失效，避免把过期结果写回工程。
public struct CalibrationView: View {
    @ObservedObject private var model: StudioModel
    @ObservedObject private var calibration: CalibrationModel
    private let scrollable: Bool

    @State private var isImportingPhoto = false
    @State private var isImportingSession = false
    @State private var isExportingPattern = false
    @State private var patternDocument: DataFileDocument?

    public init(model: StudioModel, scrollable: Bool = true) {
        self.model = model
        self._calibration = ObservedObject(wrappedValue: model.calibration)
        self.scrollable = scrollable
    }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider().overlay(UITheme.panelBorder)
                stage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                statusBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(UITheme.panelBorder)
            inspector
                .frame(width: 384)
        }
        .background(UITheme.windowBackground)
        .fileImporter(
            isPresented: $isImportingPhoto,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    try calibration.importPhoto(from: url)
                } catch {
                    calibration.errorMessage = StudioModel.message(for: error)
                }
            case .failure(let error):
                calibration.errorMessage = "导入照片失败：\(error.localizedDescription)"
            }
        }
        .fileImporter(
            isPresented: $isImportingSession,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    try calibration.openSession(from: url)
                    model.recordCalibrationSession(path: url)
                } catch {
                    calibration.errorMessage = StudioModel.message(for: error)
                }
            case .failure(let error):
                calibration.errorMessage = "打开标定记录失败：\(error.localizedDescription)"
            }
        }
        .fileExporter(
            isPresented: $isExportingPattern,
            document: patternDocument,
            contentType: .png,
            defaultFilename: "calibration-pattern.png"
        ) { result in
            if case .failure(let error) = result {
                calibration.errorMessage = "导出图案失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 头部 / 舞台 / 状态

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("辅助标定")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(UITheme.textPrimary)
                    if model.calibrationParametersUpdated {
                        BadgeView("参数已更新", colour: UITheme.success)
                    }
                    BadgeView(model.project.familyLabel)
                }
                Text("生成标定盘 → 拍照矫正 → 沿一条径向曲线描点 → 反推并应用实测参数。")
                    .font(.caption)
                    .foregroundStyle(UITheme.textSecondary)
            }
            Spacer(minLength: 8)
            if calibration.hasPhoto {
                Picker("步骤", selection: stepBinding) {
                    ForEach(CalibrationModel.Step.allCases) { step in
                        Text(step.title).tag(step)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 330)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(UITheme.sidebarBackground)
    }

    private var stepBinding: Binding<CalibrationModel.Step> {
        Binding(
            get: { calibration.step },
            set: { newStep in
                switch newStep {
                case .photo:
                    if calibration.step != .photo { calibration.backToPhoto() }
                case .trace:
                    if calibration.rectification != nil, !calibration.rectificationConfirmed {
                        calibration.confirmRectification()
                    }
                }
            }
        )
    }

    @ViewBuilder
    private var stage: some View {
        if let photo = calibration.photoImage {
            if calibration.step == .trace, let rectified = calibration.rectifiedImage {
                VStack(spacing: 8) {
                    CalibrationTraceCanvas(
                        image: rectified,
                        canvasOuterRadiusMm: calibration.photoCanvasOuterRadiusMm,
                        physicalOuterRadiusMm: calibration.discSize.physicalOuterRadiusMm,
                        holeRadiusMm: CalibrationDiscSize.standard12cm.physicalHoleRadiusMm,
                        tracePoints: calibration.tracePoints,
                        prediction: calibration.predictionOutline,
                        outlierIndices: calibration.outlierIndices,
                        selectedIndex: calibration.selectedTraceIndex,
                        onAdd: calibration.addTracePoint,
                        onMove: calibration.moveTracePoint,
                        onDelete: calibration.removeSelectedTracePoint
                    )
                    .padding(.horizontal, 12)
                    traceLegend
                }
                .padding(.bottom, 4)
            } else if let rectified = calibration.rectifiedImage, calibration.rectification != nil {
                VStack(spacing: 8) {
                    RasterImageView(rectified, label: "矫正预览（正视盘面）")
                        .aspectRatio(1, contentMode: .fit)
                        .padding(12)
                    HStack(spacing: 12) {
                        Text(calibration.rectification?.message ?? "照片矫正预览")
                            .font(.caption)
                            .foregroundStyle(UITheme.textSecondary)
                        Spacer()
                        Button("返回修正照片") { calibration.backToPhoto() }
                            .buttonStyle(.bordered)
                        Button("确认矫正，开始描线") { calibration.confirmRectification() }
                            .buttonStyle(.borderedProminent)
                            .tint(UITheme.accent)
                            .disabled(!calibration.canConfirmRectification)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            } else {
                VStack(spacing: 8) {
                    CalibrationPhotoCanvas(
                        image: photo,
                        outerBoundary: calibration.outerBoundary,
                        holeBoundary: calibration.holeBoundary,
                        onMove: calibration.moveBoundaryPoint
                    )
                    .padding(.horizontal, 12)
                    photoLegend
                }
                .padding(.bottom, 4)
            }
        } else {
            EmptyStateView(
                systemImage: "camera.viewfinder",
                title: "导入一张标定盘照片",
                message: "把「实体外缘」和「中心孔边缘」两组控制点拖到正确位置，\n计算矫正后再沿一条径向曲线描点。"
            )
        }
    }

    private var photoLegend: some View {
        HStack(spacing: 14) {
            CalibrationLegendDot(colour: UITheme.accent, text: "实体外缘")
            CalibrationLegendDot(colour: Color(red: 0.98, green: 0.45, blue: 0.72), text: "中心孔边缘")
            Spacer()
            Text("拖动控制点；点到盘心之外的区域不算盘面")
                .font(.caption2)
                .foregroundStyle(UITheme.textTertiary)
        }
        .padding(.horizontal, 16)
    }

    private var traceLegend: some View {
        HStack(spacing: 14) {
            CalibrationLegendDot(colour: UITheme.accent, text: "实拍输入")
            CalibrationLegendDot(colour: Color(red: 1.0, green: 0.62, blue: 0.2), text: "参数预测")
            CalibrationLegendDot(colour: UITheme.danger, text: "偏离较大")
            Spacer()
            Text(calibration.traceSummary)
                .font(.caption2)
                .foregroundStyle(UITheme.textTertiary)
        }
        .padding(.horizontal, 16)
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = calibration.errorMessage {
                StatusBanner(.error, error)
            }
            HStack(spacing: 8) {
                if calibration.isFitting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: calibration.step == .photo ? "1.circle" : "2.circle")
                        .foregroundStyle(UITheme.accent)
                }
                Text(calibration.statusMessage)
                    .font(.caption)
                    .foregroundStyle(UITheme.textSecondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if let sessionPath = calibration.sessionPath {
                    Text(sessionPath.lastPathComponent)
                        .font(.caption2.monospaced())
                        .foregroundStyle(UITheme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(UITheme.sidebarBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(UITheme.panelBorder).frame(height: 1)
        }
    }

    // MARK: - 检查器

    private var inspector: some View {
        PageScaffold(scrollable: scrollable) {
            VStack(alignment: .leading, spacing: 14) {
                patternCard
                photoCard
                traceCard
                sessionCard
            }
            .padding(14)
        }
        .background(UITheme.sidebarBackground)
    }

    // MARK: 生成标定盘

    private var patternCard: some View {
        SectionCard(
            "生成标定盘",
            subtitle: "按当前工程几何生成 2400×2400 图案，并固定生成快照。",
            systemImage: "opticaldisc"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                MetricRow("介质", model.project.familyLabel)
                MetricRow("数据区", String(
                    format: "%.3f – %.3f mm",
                    model.project.geometry.innerRadiusMm,
                    model.project.geometry.outerRadiusMm
                ), monospaced: true)
                MetricRow("扇区数", model.project.geometry.sectors.formatted(), monospaced: true)
                MetricRow("图案尺寸", "2400 × 2400 px")

                if let pattern = calibration.patternImage {
                    RasterImageView(pattern, label: "标定图案")
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxHeight: 120)
                        .padding(.vertical, 2)
                }

                Button {
                    generatePattern()
                } label: {
                    Label(calibration.generation == nil ? "生成图案并保存记录" : "按当前参数重新生成", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(UITheme.accent)

                HStack(spacing: 8) {
                    Button("导出图案 PNG…") { preparePatternExport() }
                        .buttonStyle(.bordered)
                        .disabled(calibration.generation == nil)
                    Button("打开标定记录…") { isImportingSession = true }
                        .buttonStyle(.bordered)
                }

                if let patternURL = calibration.generatedPatternURL {
                    Text(patternURL.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(UITheme.textTertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
    }

    // MARK: 第一步

    private var photoCard: some View {
        SectionCard(
            "第一步 · 照片矫正",
            subtitle: "拖两组控制点到实体外缘 / 中心孔边缘；12 cm 与 8 cm 只影响照片尺度。",
            systemImage: "camera"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        isImportingPhoto = true
                    } label: {
                        Label("导入盘片照片…", systemImage: "photo.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(UITheme.accent)
                    Spacer()
                    if calibration.hasPhoto {
                        Button("重新导入") { isImportingPhoto = true }
                            .buttonStyle(.borderless)
                    }
                }

                Picker("盘片规格", selection: Binding(
                    get: { calibration.discSize },
                    set: { calibration.setDiscSize($0) }
                )) {
                    ForEach(CalibrationDiscSize.allCases) { size in
                        Text(size.displayNameZH).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text("初始轮廓只供调整，不代表已识别准确；不要把刻录区边界或透明塑料环当成实体边缘。")
                    .font(.caption2)
                    .foregroundStyle(UITheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    do { try calibration.rectify() } catch { calibration.errorMessage = StudioModel.message(for: error) }
                } label: {
                    Label("计算矫正", systemImage: "perspective")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!calibration.canRectify)

                if let result = calibration.rectification {
                    Text(result.message)
                        .font(.caption)
                        .foregroundStyle(UITheme.textSecondary)
                    Text(String(format: "外缘偏差 %.1f 像素 · 内缘偏差 %.1f 像素", result.outerRmsPixels, result.holeRmsPixels))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(UITheme.textTertiary)
                }

                HStack(spacing: 8) {
                    Button("确认矫正，开始描线") { calibration.confirmRectification() }
                        .buttonStyle(.borderedProminent)
                        .tint(UITheme.accent)
                        .disabled(!calibration.canConfirmRectification)
                    if calibration.rectification != nil || calibration.step == .trace {
                        Button("返回修正照片") { calibration.backToPhoto() }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    // MARK: 第二步

    private var traceCard: some View {
        SectionCard(
            "第二步 · 单条曲线标定",
            subtitle: "沿一条清楚的径向曲线由内向外打点；建议 16 点以上，覆盖刻录环带的大部分宽度。",
            systemImage: "scribble.variable"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if model.project.discFamily == .dvd {
                    Toggle("拟合 DVD 三次轨距分布", isOn: $calibration.fitDvdPitch)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }

                Toggle("自动扩大搜索范围（±0.02 → 0.1 → 0.5 mm）", isOn: $calibration.autoRange)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                if calibration.autoRange {
                    Text("自动档位：±0.02 → ±0.1 → ±0.5 mm；最优解贴边时自动扩大后再算。")
                        .font(.caption2)
                        .foregroundStyle(UITheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 8) {
                        Text("手动范围 ±")
                            .font(.caption)
                            .foregroundStyle(UITheme.textSecondary)
                        TextField("0.020", value: $calibration.manualSearchRangeMm, format: .number.precision(.fractionLength(3)))
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospacedDigit())
                            .frame(width: 74)
                        Text("mm")
                            .font(.caption)
                            .foregroundStyle(UITheme.textSecondary)
                        Spacer()
                    }
                    Slider(
                        value: $calibration.manualSearchRangeMm,
                        in: CalibrationModel.manualSearchRangeLimits,
                        step: CalibrationModel.manualSearchRangeStep
                    )
                    .disabled(calibration.isFitting)
                    if let error = calibration.searchRangeValidationMessage {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(UITheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("矫正已确认后：点击空白加点、拖动圆点修正、Delete 或下方按钮删点。")
                    .font(.caption2)
                    .foregroundStyle(UITheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button {
                        calibration.startFit()
                    } label: {
                        Label(
                            calibration.isFitting ? "正在后台反推…" : "反推参数",
                            systemImage: calibration.isFitting ? "hourglass" : "function"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(UITheme.accent)
                    .disabled(!calibration.canStartFit)

                    if calibration.isFitting {
                        Button("取消反推") { calibration.cancelFit() }
                            .buttonStyle(.bordered)
                    } else {
                        Button("删除选中点") { calibration.removeSelectedTracePoint() }
                            .buttonStyle(.bordered)
                            .disabled(calibration.selectedTraceIndex == nil)
                    }
                    Button("清空曲线") { calibration.clearTrace() }
                        .buttonStyle(.bordered)
                        .disabled(calibration.tracePoints.isEmpty || calibration.isFitting)
                }

                if calibration.isFitting {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("计算中…（主线程不受影响，可随时取消）")
                            .font(.caption2)
                            .foregroundStyle(UITheme.textSecondary)
                    }
                }

                Text(calibration.fitAssessment)
                    .font(.caption2)
                    .foregroundStyle(calibration.canApplySelectedCandidate ? UITheme.textSecondary : UITheme.warning)
                    .fixedSize(horizontal: false, vertical: true)

                if !calibration.candidates.isEmpty {
                    Picker("候选", selection: Binding(
                        get: { calibration.selectedCandidateIndex ?? 0 },
                        set: { calibration.selectCandidate(at: $0) }
                    )) {
                        ForEach(Array(calibration.candidates.enumerated()), id: \.offset) { index, candidate in
                            Text(candidateLabel(candidate, index: index))
                                .tag(index)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let selected = calibration.selectedCandidate {
                    VStack(alignment: .leading, spacing: 3) {
                        MetricRow("内半径", String(format: "%.4f mm", selected.innerRadiusMm), monospaced: true)
                        MetricRow("外半径", String(format: "%.4f mm", selected.outerRadiusMm), monospaced: true)
                        MetricRow("转角", String(format: "%.4f rad", selected.rotationRadians), monospaced: true)
                        if selected.hasCubicPitch {
                            MetricRow("c₁ / c₂ / c₃", String(
                                format: "%.3g / %.3g / %.3g",
                                selected.pitchLinear,
                                selected.pitchQuadratic,
                                selected.pitchCubic
                            ), monospaced: true)
                        }
                    }
                }

                if calibration.fitResult?.boundaryLimited == true {
                    StatusBanner(.warning, "结果受搜索边界限制，不可信；请补点，或关闭自动档位后手动扩大搜索范围再算。")
                }

                if let rejection = calibration.selectedCandidateRejectionReason,
                   calibration.fitResult != nil {
                    StatusBanner(.warning, rejection)
                }

                if let warnings = calibration.fitResult?.warnings, !warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                            Text("· \(warning)")
                                .font(.caption2)
                                .foregroundStyle(UITheme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Button {
                    applyCandidate()
                } label: {
                    Label("应用标定参数", systemImage: "checkmark.seal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(UITheme.success)
                .disabled(!calibration.canApplySelectedCandidate)

                Text("应用只更新内外半径（DVD 另含三次轨距），并在工程头显示「参数已更新」。")
                    .font(.caption2)
                    .foregroundStyle(UITheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 记录

    private var sessionCard: some View {
        SectionCard("标定记录", subtitle: "记录含生成快照、照片（base64）与曲线点；候选不持久化。", systemImage: "doc.badge.clock") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button {
                        saveSession()
                    } label: {
                        Label("保存标定记录", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!calibration.canSaveSession)

                    Button {
                        isImportingSession = true
                    } label: {
                        Label("打开标定记录…", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }

                if let sessionPath = calibration.sessionPath {
                    Text(sessionPath.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(UITheme.textTertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                } else {
                    Text("将保存到：\(defaultSessionURL.path)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(UITheme.textTertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                Text("生成图案时会自动写一份 `.calibration.json`；之后可继续描点、重新反推。")
                    .font(.caption2)
                    .foregroundStyle(UITheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 动作

    private var defaultCalibrationDirectory: URL {
        let outputPath = model.project.outputs.outputPath
        let baseDirectory = outputPath.isEmpty
            ? ProjectStore.defaultProjectsDirectory
            : URL(fileURLWithPath: outputPath).deletingLastPathComponent()
        return baseDirectory
            .appendingPathComponent("\(ProjectNaming.sanitizedFileStem(model.project.name))-calibration", isDirectory: true)
    }

    private var defaultSessionURL: URL {
        defaultCalibrationDirectory.appendingPathComponent(CalibrationModel.sessionFileName)
    }

    private func candidateLabel(_ candidate: CalibrationFitCandidate, index: Int) -> String {
        let suffix = candidate.isApplicable ? "" : " · 不可应用"
        return String(format: "候选 %d · 偏差 %.3f mm%@", index + 1, candidate.rmsErrorMm, suffix)
    }

    private func generatePattern() {
        do {
            let urls = try calibration.generatePattern(
                project: model.project,
                outputDirectory: defaultCalibrationDirectory
            )
            model.recordCalibrationSession(path: urls.sessionURL)
            model.statusMessage = "标定图案与记录已生成：\(urls.patternURL.lastPathComponent)"
        } catch {
            calibration.errorMessage = StudioModel.message(for: error)
        }
    }

    private func saveSession() {
        do {
            let url = calibration.sessionPath ?? defaultSessionURL
            try calibration.saveSession(to: url)
            model.recordCalibrationSession(path: url)
            model.statusMessage = "标定记录已保存：\(url.lastPathComponent)"
        } catch {
            calibration.errorMessage = StudioModel.message(for: error)
        }
    }

    private func preparePatternExport() {
        do {
            guard let image = try calibration.loadPatternImageIfNeeded() else {
                throw DiscError.missingPayload("还没有标定图案，请先生成。")
            }
            patternDocument = DataFileDocument(data: try image.pngData())
            isExportingPattern = true
        } catch {
            calibration.errorMessage = StudioModel.message(for: error)
        }
    }

    private func applyCandidate() {
        guard let candidate = calibration.selectedCandidate else { return }
        do {
            try model.applyCalibrationCandidate(candidate, sessionPath: calibration.sessionPath)
            model.statusMessage = "标定参数已更新；原标定记录仍保留，可继续补点核对。"
        } catch {
            calibration.errorMessage = StudioModel.message(for: error)
        }
    }
}
