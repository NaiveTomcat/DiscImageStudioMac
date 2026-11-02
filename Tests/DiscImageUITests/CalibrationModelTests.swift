import DiscImageCore
import XCTest
@testable import DiscImageUI

/// GUI 标定闭环：生成图案、照片矫正、曲线反推、应用参数、会话往返。
@MainActor
final class CalibrationModelTests: XCTestCase {
    private var scratch: URL!
    private var recentStore: RecentProjectStore!

    override func setUpWithError() throws {
        scratch = try UITestSupport.makeTempDirectory("calibration-model")
        recentStore = RecentProjectStore(fileURL: scratch.appendingPathComponent("recent.json"))
    }

    override func tearDownWithError() throws {
        UITestSupport.removeQuietly(scratch)
    }

    private func makeStudioModel() -> StudioModel {
        var project = UITestSupport.sampleProject(family: .dvd)
        project.name = "标定测试"
        project.geometry = UITestSupport.calibrationGeometry()
        return StudioModel(project: project, recentStore: recentStore)
    }

    private func snapshot(for project: DiscProject) -> CalibrationGenerationSnapshot {
        CalibrationGenerationSnapshot(
            geometry: project.geometry,
            tone: project.effectiveTone,
            drawingStartSector: 0,
            drawingEndSectorExclusive: 0,
            cdInterleave: false
        )
    }

    /// 准备到「第二步、矫正已确认」的状态。
    private func prepareTraceStep(
        studio: StudioModel,
        pointRadii: [Double]? = nil
    ) throws {
        let session = CalibrationSession(generation: snapshot(for: studio.project))
        try studio.calibration.loadSession(session)
        try studio.calibration.importPhoto(UITestSupport.syntheticDiscPhoto(size: 320))
        try studio.calibration.rectify()
        studio.calibration.confirmRectification()
        let radii = pointRadii ?? stride(from: 26.0, through: 38.0, by: 1.5).map { $0 }
        for radius in radii {
            studio.calibration.addTracePoint(CalibrationPoint(xMm: radius, yMm: 0))
        }
    }

    // MARK: - 生成标定盘

    func testGeneratePatternWritesPNGAndSessionSnapshot() throws {
        let studio = makeStudioModel()
        let directory = scratch.appendingPathComponent("pattern", isDirectory: true)

        let urls = try studio.calibration.generatePattern(
            project: studio.project,
            outputDirectory: directory
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: urls.patternURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls.sessionURL.path))
        let pattern = try RasterImage.load(contentsOf: urls.patternURL)
        XCTAssertEqual(pattern.width, CalibrationModel.patternPixelSize)
        XCTAssertEqual(pattern.height, CalibrationModel.patternPixelSize)

        let session = try CalibrationSessionStore.load(from: urls.sessionURL)
        XCTAssertEqual(session.generation.geometry, studio.project.geometry)
        XCTAssertEqual(session.generation.schemaVersion, CalibrationGenerationSnapshot.currentSchemaVersion)
        XCTAssertNil(session.photo, "新建图案时不应带上一张盘的照片")

        XCTAssertEqual(studio.calibration.generation?.geometry, studio.project.geometry)
        XCTAssertEqual(studio.calibration.sessionPath, urls.sessionURL)
        XCTAssertEqual(studio.calibration.step, .photo)
        XCTAssertNil(studio.calibration.photoImage)

        // 生成后改工程参数，已保存记录不能跟着变（快照固定）。
        studio.project.geometry.innerRadiusMm = 25.5
        let reloaded = try CalibrationSessionStore.load(from: urls.sessionURL)
        XCTAssertEqual(reloaded.generation.geometry.innerRadiusMm, 24, accuracy: 1e-9)
    }

    // MARK: - 照片矫正 + 会话往返

    func testPhotoRectificationAndSessionRoundTrip() throws {
        let studio = makeStudioModel()
        try prepareTraceStep(studio: studio)

        XCTAssertEqual(studio.calibration.step, .trace)
        XCTAssertTrue(studio.calibration.rectificationConfirmed)
        XCTAssertNotNil(studio.calibration.rectifiedImage)
        XCTAssertNotNil(studio.calibration.rectification)
        XCTAssertEqual(studio.calibration.tracePoints.count, 9)
        XCTAssertTrue(studio.calibration.tracePoints.map(\.radiusMm).sorted() == studio.calibration.tracePoints.map(\.radiusMm),
                      "曲线点应按半径从内到外排列")

        let session = try studio.calibration.makeSession()
        let photo = try XCTUnwrap(session.photo)
        XCTAssertFalse(photo.imagePngBase64.isEmpty)
        XCTAssertTrue(photo.rectificationConfirmed)
        XCTAssertEqual(photo.traces.first?.points.count, 9)
        XCTAssertEqual(photo.discSize, .standard12cm)

        // JSON 往返：照片 base64、边界、曲线点都要原样保留。
        let data = try CalibrationSessionStore.encode(session)
        let decoded = try CalibrationSessionStore.decode(data)
        XCTAssertEqual(decoded.photo?.imagePngBase64, photo.imagePngBase64)
        XCTAssertEqual(decoded.photo?.outerBoundary, photo.outerBoundary)
        XCTAssertEqual(decoded.photo?.holeBoundary, photo.holeBoundary)
        XCTAssertEqual(decoded.photo?.discSize, photo.discSize)
        XCTAssertEqual(decoded.photo?.rectificationConfirmed, true)
        XCTAssertEqual(decoded.photo?.traces, photo.traces)
        XCTAssertEqual(decoded.generation.geometry, studio.project.geometry)

        // 写文件 → 新模型打开 → 照片、边界、曲线点都恢复；候选不持久化。
        let url = scratch.appendingPathComponent("roundtrip.calibration.json")
        try CalibrationSessionStore.save(decoded, to: url)
        let reopened = CalibrationModel()
        try reopened.openSession(from: url)
        XCTAssertNotNil(reopened.photoImage)
        XCTAssertEqual(reopened.outerBoundary, photo.outerBoundary)
        XCTAssertEqual(reopened.holeBoundary, photo.holeBoundary)
        XCTAssertTrue(reopened.rectificationConfirmed)
        XCTAssertEqual(reopened.step, .trace)
        XCTAssertNotNil(reopened.rectifiedImage)
        XCTAssertEqual(reopened.tracePoints, photo.traces.first?.points)
        XCTAssertNil(reopened.fitResult, "候选不持久化，打开后应重新反推")
        XCTAssertFalse(reopened.canApplySelectedCandidate)
    }

    // MARK: - 反推 + 应用

    func testFitProducesPredictionAndApplyingUpdatesGeometry() throws {
        let studio = makeStudioModel()
        try prepareTraceStep(studio: studio)

        studio.calibration.fit()

        let result = try XCTUnwrap(studio.calibration.fitResult, "应得到反推结果")
        XCTAssertTrue(result.succeeded, "拟合失败：\(result.warnings)")
        XCTAssertFalse(studio.calibration.candidates.isEmpty)
        XCTAssertNotNil(studio.calibration.selectedCandidate)
        XCTAssertGreaterThan(studio.calibration.predictionOutline.count, 1, "应生成橙色预测叠线")
        XCTAssertEqual(studio.calibration.pointDistances.count, studio.calibration.tracePoints.count)
        XCTAssertTrue(studio.calibration.canApplySelectedCandidate, "偏差应在可应用门槛内：\(studio.calibration.fitAssessment)")

        let candidate = try XCTUnwrap(studio.calibration.selectedCandidate)
        let before = studio.project.geometry
        let sessionURL = scratch.appendingPathComponent("roundtrip.calibration.json")

        try studio.applyCalibrationCandidate(candidate, sessionPath: sessionURL)

        XCTAssertTrue(studio.calibrationParametersUpdated, "应用后应亮起「参数已更新」")
        XCTAssertTrue(studio.statusMessage?.contains("参数已更新") ?? false)
        XCTAssertEqual(studio.project.calibrationSessionPath, sessionURL.path)
        XCTAssertEqual(studio.project.geometry.innerRadiusMm, candidate.innerRadiusMm, accuracy: 1e-12)
        XCTAssertEqual(studio.project.geometry.outerRadiusMm, candidate.outerRadiusMm, accuracy: 1e-12)
        XCTAssertEqual(studio.project.geometry, candidate.applying(to: before))
        XCTAssertTrue(studio.isDirty)
    }

    func testInapplicableCandidateIsRejectedAndGeometryUntouched() throws {
        let studio = makeStudioModel()
        let before = studio.project.geometry
        let badCandidate = CalibrationFitCandidate(
            innerRadiusMm: 24.4,
            outerRadiusMm: 40.3,
            rotationRadians: 0,
            rmsErrorMm: 1.2,
            maxErrorMm: 2.4
        )
        XCTAssertFalse(badCandidate.isApplicable)
        XCTAssertFalse(studio.calibration.canApply(badCandidate), "不可应用的候选必须禁用按钮")
        XCTAssertThrowsError(try studio.applyCalibrationCandidate(badCandidate))
        XCTAssertEqual(studio.project.geometry, before, "拒绝应用时不能改动工程几何")
        XCTAssertFalse(studio.calibrationParametersUpdated)
    }

    func testTooFewTracePointsKeepsApplyDisabled() throws {
        let studio = makeStudioModel()
        let session = CalibrationSession(generation: snapshot(for: studio.project))
        try studio.calibration.loadSession(session)
        try studio.calibration.importPhoto(UITestSupport.syntheticDiscPhoto(size: 256))
        try studio.calibration.rectify()
        studio.calibration.confirmRectification()
        studio.calibration.addTracePoint(CalibrationPoint(xMm: 26, yMm: 0))
        studio.calibration.addTracePoint(CalibrationPoint(xMm: 30, yMm: 0))

        studio.calibration.fit()

        XCTAssertNotNil(studio.calibration.fitResult)
        XCTAssertFalse(studio.calibration.fitResult?.succeeded ?? true)
        XCTAssertTrue(studio.calibration.candidates.isEmpty)
        XCTAssertNil(studio.calibration.selectedCandidate)
        XCTAssertFalse(studio.calibration.canApplySelectedCandidate, "没有可用候选时应用按钮必须禁用")
        XCTAssertNotNil(studio.calibration.selectedCandidateRejectionReason)
        XCTAssertTrue(studio.calibration.statusMessage.contains("6 个点") || studio.calibration.statusMessage.contains("覆盖"))
    }

    func testEditingTraceInvalidatesFit() throws {
        let studio = makeStudioModel()
        try prepareTraceStep(studio: studio)
        studio.calibration.fit()
        XCTAssertNotNil(studio.calibration.fitResult)
        XCTAssertTrue(studio.calibration.canApplySelectedCandidate)

        studio.calibration.addTracePoint(CalibrationPoint(xMm: 34 * cos(0.2), yMm: 34 * sin(0.2)))

        XCTAssertNil(studio.calibration.fitResult, "改曲线后旧拟合必须失效")
        XCTAssertTrue(studio.calibration.predictionOutline.isEmpty)
        XCTAssertFalse(studio.calibration.canApplySelectedCandidate)
        XCTAssertTrue(studio.calibration.statusMessage.contains("重新反推"))
    }

    func testBoundaryEditInvalidatesRectification() throws {
        let studio = makeStudioModel()
        try prepareTraceStep(studio: studio)
        studio.calibration.fit()
        XCTAssertTrue(studio.calibration.rectificationConfirmed)

        studio.calibration.moveBoundaryPoint(
            .outer,
            index: 0,
            to: CalibrationPoint(xMm: 10, yMm: 10)
        )

        XCTAssertNil(studio.calibration.rectification)
        XCTAssertNil(studio.calibration.rectifiedImage)
        XCTAssertFalse(studio.calibration.rectificationConfirmed)
        XCTAssertEqual(studio.calibration.step, .photo)
        XCTAssertTrue(studio.calibration.tracePoints.isEmpty, "轮廓失效后曲线点不能保留")
        XCTAssertNil(studio.calibration.fitResult)
    }

    func testDiscSizeChangeInvalidatesRectification() throws {
        let studio = makeStudioModel()
        try prepareTraceStep(studio: studio)
        studio.calibration.setDiscSize(.mini8cm)
        XCTAssertNil(studio.calibration.rectification)
        XCTAssertFalse(studio.calibration.rectificationConfirmed)
        XCTAssertEqual(studio.calibration.photoCanvasOuterRadiusMm, 43, accuracy: 1e-9)
    }

    func testSaveAndOpenSessionFile() throws {
        let studio = makeStudioModel()
        try prepareTraceStep(studio: studio)
        studio.calibration.fit()
        let url = scratch.appendingPathComponent("saved.calibration.json")

        try studio.calibration.saveSession(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(studio.calibration.sessionPath, url)

        let reopened = CalibrationModel()
        try reopened.openSession(from: url)
        XCTAssertEqual(reopened.sessionPath, url)
        XCTAssertEqual(reopened.tracePoints.count, 9)
        XCTAssertTrue(reopened.rectificationConfirmed)
        XCTAssertNil(reopened.fitResult)
    }

    // MARK: - 后台反推 / 取消 / 手动范围

    func testAsyncFitCompletesWithDuration() async throws {
        let studio = makeStudioModel()
        try prepareTraceStep(studio: studio)

        studio.calibration.startFit()
        XCTAssertTrue(studio.calibration.isFitting, "反推应在后台开始")
        try await UITestSupport.waitUntil(timeout: 60) { !studio.calibration.isFitting }

        XCTAssertNotNil(studio.calibration.fitResult)
        let duration = try XCTUnwrap(studio.calibration.lastFitDuration)
        XCTAssertGreaterThanOrEqual(duration, 0)
        XCTAssertTrue(studio.calibration.statusMessage.contains("耗时"), studio.calibration.statusMessage)
        XCTAssertNil(studio.calibration.errorMessage)
        XCTAssertFalse(studio.calibration.isFitting)
    }

    func testCancelFitReturnsToIdleWithoutError() async throws {
        let studio = makeStudioModel()
        // 间距 >1.2 mm 才不会被「点已存在」的去重逻辑吞掉；12 个不同半径会走三次轨距拟合。
        let radii = stride(from: 25.0, through: 39.0, by: 1.25).map { $0 }
        try prepareTraceStep(studio: studio, pointRadii: radii)
        let expectedCount = studio.calibration.tracePoints.count
        XCTAssertEqual(expectedCount, 12)

        studio.calibration.startFit()
        XCTAssertTrue(studio.calibration.isFitting)
        studio.calibration.cancelFit()

        try await UITestSupport.waitUntil(timeout: 60) { !studio.calibration.isFitting }

        XCTAssertNil(studio.calibration.fitResult, "取消后不应留下结果")
        XCTAssertNil(studio.calibration.errorMessage, "取消不应弹错误框")
        XCTAssertTrue(
            studio.calibration.statusMessage.contains("已取消"),
            "取消后状态行应提示已取消，实际：\(studio.calibration.statusMessage)"
        )
        XCTAssertEqual(studio.calibration.tracePoints.count, expectedCount, "取消必须保留全部曲线点")
        XCTAssertFalse(studio.calibration.canApplySelectedCandidate)
    }

    /// Core 的取消契约：已取消的 Flag 必须抛 `CancellationError`（UI 据此静默回空闲）。
    func testCoreFitterThrowsCancellationErrorWithPreCancelledFlag() throws {
        let studio = makeStudioModel()
        try prepareTraceStep(studio: studio)
        let session = try studio.calibration.makeSession()
        let flag = CancellationFlag()
        flag.cancel()

        XCTAssertThrowsError(try CalibrationCrossFitter.fit(
            session: session,
            points: studio.calibration.tracePoints,
            options: studio.calibration.effectiveFitOptions,
            cancellation: flag
        )) { error in
            XCTAssertTrue(error is CancellationError, "应抛 CancellationError，实际 \(error)")
        }
    }

    func testManualSearchRangeValidationAndOptions() throws {
        let studio = makeStudioModel()
        try prepareTraceStep(studio: studio)

        // 默认自动档：±0.02 起步、autoRange = true。
        XCTAssertTrue(studio.calibration.autoRange)
        XCTAssertNil(studio.calibration.searchRangeValidationMessage)
        XCTAssertTrue(studio.calibration.effectiveFitOptions.autoRange)
        XCTAssertEqual(studio.calibration.effectiveFitOptions.searchRangeMm, 0.02, accuracy: 1e-12)

        studio.calibration.autoRange = false
        studio.calibration.manualSearchRangeMm = 0.002
        XCTAssertNotNil(studio.calibration.searchRangeValidationMessage)
        XCTAssertFalse(studio.calibration.canStartFit)
        studio.calibration.startFit()
        XCTAssertFalse(studio.calibration.isFitting, "非法范围不应真的启动反推")
        XCTAssertNotNil(studio.calibration.errorMessage)
        XCTAssertNil(studio.calibration.fitResult)

        studio.calibration.manualSearchRangeMm = 1.5
        XCTAssertNotNil(studio.calibration.searchRangeValidationMessage)

        studio.calibration.manualSearchRangeMm = 0.012
        XCTAssertNotNil(studio.calibration.searchRangeValidationMessage)
        XCTAssertTrue(studio.calibration.searchRangeValidationMessage?.contains("步进") ?? false)

        studio.calibration.manualSearchRangeMm = 0.05
        XCTAssertNil(studio.calibration.searchRangeValidationMessage)
        XCTAssertTrue(studio.calibration.canStartFit)
        let options = studio.calibration.effectiveFitOptions
        XCTAssertFalse(options.autoRange)
        XCTAssertEqual(options.searchRangeMm, 0.05, accuracy: 1e-12)
    }

    /// 缩放/平移只影响显示：会话里保存的照片 base64、边界、曲线点都不能变。
    func testViewportTransformDoesNotChangeStoredPhotoCoordinates() throws {
        let studio = makeStudioModel()
        try prepareTraceStep(studio: studio)
        let before = try XCTUnwrap(try studio.calibration.makeSession().photo)
        let image = try XCTUnwrap(studio.calibration.photoImage)

        let layout = PhotoLayout(
            imageSize: CGSize(width: image.width, height: image.height),
            bounds: CGSize(width: 640, height: 520)
        )
        let viewport = CanvasViewport(zoom: 3.2, pan: CGSize(width: 70, height: -30))
        let mapping = PhotoCanvasMapping(
            layout: layout,
            viewport: viewport,
            centre: CGPoint(x: 320, y: 260)
        )
        let imagePoint = CalibrationPoint(xMm: 100, yMm: 200)
        let back = mapping.imagePoint(mapping.displayPoint(imagePoint))
        XCTAssertEqual(back.xMm, imagePoint.xMm, accuracy: 1e-9)
        XCTAssertEqual(back.yMm, imagePoint.yMm, accuracy: 1e-9)

        let after = try XCTUnwrap(try studio.calibration.makeSession().photo)
        XCTAssertEqual(after.imagePngBase64, before.imagePngBase64)
        XCTAssertEqual(after.outerBoundary, before.outerBoundary)
        XCTAssertEqual(after.holeBoundary, before.holeBoundary)
        XCTAssertEqual(after.traces, before.traces)
    }

    func testResetClearsEverything() throws {
        let studio = makeStudioModel()
        try prepareTraceStep(studio: studio)
        studio.calibration.fit()
        studio.calibration.reset()

        XCTAssertNil(studio.calibration.generation)
        XCTAssertNil(studio.calibration.photoImage)
        XCTAssertNil(studio.calibration.rectifiedImage)
        XCTAssertNil(studio.calibration.fitResult)
        XCTAssertTrue(studio.calibration.tracePoints.isEmpty)
        XCTAssertFalse(studio.calibration.rectificationConfirmed)
        XCTAssertEqual(studio.calibration.step, .photo)
    }
}
