import DiscImageCore
import DiscImageUI
import XCTest

/// 应用状态：新建/打开/保存工程、图层、影调、标定、导出。
@MainActor
final class StudioModelTests: XCTestCase {
    private var scratch: URL!
    private var recentStore: RecentProjectStore!

    override func setUpWithError() throws {
        scratch = try UITestSupport.makeTempDirectory("studio-model")
        recentStore = RecentProjectStore(
            fileURL: scratch.appendingPathComponent("recent-projects.json")
        )
    }

    override func tearDownWithError() throws {
        UITestSupport.removeQuietly(scratch)
    }

    private func makeModel(project: DiscProject? = nil) -> StudioModel {
        StudioModel(project: project, recentStore: recentStore)
    }

    func testDefaultModelIsBlankCDProject() {
        let model = makeModel()
        XCTAssertEqual(model.project.discFamily, .cd)
        XCTAssertEqual(model.project.geometry.sectors, DiscPreset.cd80.sectors)
        XCTAssertEqual(model.page, .home)
        XCTAssertEqual(model.project.layers.count, 0)
        XCTAssertNil(model.projectURL)
    }

    func testNewProjectFromTemplate() {
        let model = makeModel()
        model.newProject(preset: .dvd5_120mm)

        XCTAssertEqual(model.project.discFamily, .dvd)
        XCTAssertEqual(model.page, .design)
        XCTAssertFalse(model.isDirty)
        XCTAssertTrue(model.project.name.contains("DVD"))
        XCTAssertEqual(model.project.geometry.sectors, DiscPreset.dvd5_120mm.sectors)
        XCTAssertTrue(model.project.outputs.outputPath.hasSuffix(".iso"))
    }

    func testAddLayerLoadsImageAndRefreshesPreview() throws {
        let model = makeModel()
        let imageURL = try UITestSupport.writePNG(
            UITestSupport.gray(width: 64, height: 32, value: 200),
            named: "layer.png",
            in: scratch
        )

        let layer = try model.addLayer(imageURL: imageURL)

        XCTAssertEqual(model.project.layers.count, 1)
        XCTAssertEqual(model.project.layers[0].id, layer.id)
        XCTAssertEqual(model.selectedLayerID, layer.id)
        XCTAssertNotNil(model.layerImages[layer.id])
        XCTAssertNotNil(model.composedPreview)
        XCTAssertNotNil(model.discPreview)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.layerImages[layer.id]?.width, 64)
    }

    func testAddLayerRejectsMissingFile() {
        let model = makeModel()
        XCTAssertThrowsError(try model.addLayer(imageURL: scratch.appendingPathComponent("nope.png")))
        XCTAssertTrue(model.project.layers.isEmpty)
    }

    func testRemoveAndReorderLayers() throws {
        let model = makeModel()
        let first = try model.addLayer(imageURL: UITestSupport.writePNG(
            UITestSupport.gray(width: 16, height: 16, value: 10), named: "a.png", in: scratch
        ))
        let second = try model.addLayer(imageURL: UITestSupport.writePNG(
            UITestSupport.gray(width: 16, height: 16, value: 20), named: "b.png", in: scratch
        ))
        XCTAssertEqual(model.project.layers.map(\.id), [second.id, first.id], "新图层应在最上层")

        model.moveLayer(id: second.id, to: 1)
        XCTAssertEqual(model.project.layers.map(\.id), [first.id, second.id])

        model.removeLayer(id: first.id)
        XCTAssertEqual(model.project.layers.map(\.id), [second.id])
        XCTAssertNil(model.layerImages[first.id])
    }

    func testToneNormalization() {
        let model = makeModel()
        model.tone = ToneProfile(ditherStrength: 2.5, levels: 9, brightness: 999, srgbLinearization: -1)
        XCTAssertEqual(model.tone.ditherStrength, 1, accuracy: 1e-9)
        XCTAssertEqual(model.tone.levels, ToneProfile.twoLevels)
        XCTAssertEqual(model.tone.brightness, ToneProfile.maxBrightness)
        XCTAssertEqual(model.tone.srgbLinearization, 0, accuracy: 1e-9)

        model.newProject(preset: .cd80)
        model.tone = ToneProfile(levels: 4)
        XCTAssertEqual(model.tone.levels, 4, "CD 允许四阶")

        model.newProject(preset: .dvd5_120mm)
        model.tone = ToneProfile(levels: 4)
        XCTAssertEqual(model.tone.levels, 2, "DVD 只允许两阶")
    }

    func testCalibrationWritesCoefficientsAndSession() throws {
        let model = makeModel(project: UITestSupport.sampleProject(family: .dvd))
        try model.applyCalibration(
            sessionPath: "/tmp/calibration-session",
            pitchLinear: -3.9e-05,
            pitchQuadratic: 6.9e-05,
            pitchCubic: -4.6e-05,
            invertMapping: false
        )
        XCTAssertEqual(model.project.calibrationSessionPath, "/tmp/calibration-session")
        XCTAssertEqual(model.project.geometry.pitchLinear, -3.9e-05, accuracy: 1e-12)
        XCTAssertTrue(model.project.geometry.hasCubicPitch)
        XCTAssertTrue(model.isDirty)
    }

    func testInvalidCalibrationLeavesProjectUntouched() {
        let model = makeModel(project: UITestSupport.sampleProject(family: .dvd))
        let before = model.project
        XCTAssertThrowsError(try model.applyCalibration(
            sessionPath: nil,
            pitchLinear: -2.0,
            pitchQuadratic: 0,
            pitchCubic: 0,
            invertMapping: false
        ))
        XCTAssertEqual(model.project.geometry, before.geometry, "校验失败不应改动工程")
    }

    func testBluRayCalibrationSetsPolarity() throws {
        let model = makeModel(project: UITestSupport.sampleProject(family: .bluRay))
        try model.applyCalibration(
            sessionPath: nil,
            pitchLinear: 0.1,
            pitchQuadratic: 0,
            pitchCubic: 0,
            invertMapping: true
        )
        XCTAssertEqual(model.project.geometry.pitchLinear, 0, "蓝光使用恒定轨距")
        XCTAssertEqual(model.project.bluRay?.invertMapping, true)
        XCTAssertTrue(model.project.effectiveInvertMapping)
    }

    func testSaveOpenRoundTripKeepsLayers() throws {
        let model = makeModel()
        let imageURL = try UITestSupport.writePNG(
            UITestSupport.gray(width: 32, height: 32, value: 120),
            named: "saved-layer.png",
            in: scratch
        )
        let layer = try model.addLayer(imageURL: imageURL)
        model.project.name = "往返测试"
        model.project.outputs.volumeLabel = "ROUNDTRIP"

        let projectURL = scratch.appendingPathComponent("roundtrip.discproj")
        try model.saveProject(to: projectURL)

        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.projectURL, projectURL)
        XCTAssertEqual(model.recentProjects.first?.projectPath, projectURL.path)
        XCTAssertNotNil(model.project.thumbnailPngBase64, "保存时应写入缩略图")

        let reopened = makeModel()
        try reopened.openProject(at: projectURL)
        XCTAssertEqual(reopened.project.name, "往返测试")
        XCTAssertEqual(reopened.project.outputs.volumeLabel, "ROUNDTRIP")
        XCTAssertEqual(reopened.project.layers.count, 1)
        XCTAssertEqual(reopened.project.layers[0].id, layer.id)
        XCTAssertNotNil(reopened.layerImages[layer.id], "打开工程应重新解码图层图")
        XCTAssertEqual(reopened.page, .design)
        XCTAssertFalse(reopened.isDirty)
    }

    func testOpenRecentMissingFileShowsAlert() {
        let entry = RecentProjectEntry(
            name: "已删除",
            discFamily: "cd",
            projectPath: scratch.appendingPathComponent("gone.discproj").path
        )
        _ = recentStore.record(entry)

        let model = makeModel()
        XCTAssertEqual(model.recentProjects.count, 1)
        model.openRecent(entry)
        XCTAssertNotNil(model.alertMessage)
        XCTAssertTrue(model.recentProjects.isEmpty, "缺失文件的最近记录应被移除")
    }

    func testOpenCorruptedProjectThrows() throws {
        let model = makeModel()
        let url = scratch.appendingPathComponent("broken.discproj")
        try Data("{ not json".utf8).write(to: url)
        XCTAssertThrowsError(try model.openProject(at: url))
        XCTAssertEqual(model.project.discFamily, .cd, "打开失败不应破坏当前工程")
    }

    func testExportCompositeAndPreviewToFiles() throws {
        let model = makeModel()
        let layerImage = UITestSupport.verticalHalves(width: 32, height: 32)
        let imageURL = try UITestSupport.writePNG(layerImage, named: "export-layer.png", in: scratch)
        _ = try model.addLayer(imageURL: imageURL)

        let compositeURL = scratch.appendingPathComponent("composite.png")
        let raster = try model.exportComposite(to: compositeURL, size: 128)
        XCTAssertEqual(raster.width, 128)
        XCTAssertNotNil(model.statusMessage)

        let previewURL = scratch.appendingPathComponent("preview.png")
        try model.exportDiscPreview(to: previewURL, size: 256)
        let preview = try RasterImage.load(contentsOf: previewURL)
        XCTAssertEqual(preview.width, 256)
    }

    func testOutputFormatSwitchingRewritesExtension() {
        let model = makeModel()
        XCTAssertEqual(model.project.outputFormat, .wav)
        model.setOutputFormat(.raw)
        XCTAssertEqual(model.project.outputFormat, .raw)
        XCTAssertTrue(model.project.outputs.outputPath.hasSuffix(".raw"))
    }

    func testFileRegionUsesDataDirectory() throws {
        let model = makeModel(project: UITestSupport.sampleProject(family: .dvd))
        let dataDirectory = scratch.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4096).write(to: dataDirectory.appendingPathComponent("a.bin"))

        model.project.outputs.dataDirectory = dataDirectory.path
        model.refreshFileRegion()
        XCTAssertNotNil(model.fileRegion)

        model.project.outputs.dataDirectory = ""
        model.refreshFileRegion()
        XCTAssertNil(model.fileRegion)
    }

    func testEngineAvailabilityBanner() {
        let model = makeModel(project: UITestSupport.sampleProject(family: .cd))
        XCTAssertTrue(model.canExport)
        XCTAssertNil(model.engineUnavailableReason)

        let dvdModel = makeModel(project: UITestSupport.sampleProject(family: .dvd))
        if !dvdModel.canExport {
            XCTAssertNotNil(dvdModel.engineUnavailableReason)
            XCTAssertTrue(dvdModel.engineUnavailableReason!.contains("工作包"))
        }
    }

    func testPageNavigationAndNaming() {
        let model = makeModel()
        model.navigate(to: .preview)
        XCTAssertEqual(model.page, .preview)
        model.navigate(to: .calibration)
        XCTAssertEqual(model.page, .calibration)
        model.newProject(preset: .cd80, name: "小蓝鲸")
        XCTAssertEqual(model.project.name, "小蓝鲸")
        XCTAssertEqual(model.page, .design)
        model.project.name = "改名"
        XCTAssertTrue(model.displayTitle.contains("已修改"))
    }
}
