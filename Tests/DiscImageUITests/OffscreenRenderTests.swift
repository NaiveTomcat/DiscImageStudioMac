import DiscImageCore
import DiscImageUI
import SwiftUI
import XCTest

/// UI 回归手段：用 `ImageRenderer` 离屏渲染页面到 PNG。
///
/// 没有像素基线，只断言：PNG 非空、尺寸正确、画面不是单一纯色。
/// 产物写到工作区的 `.build-ui/ui-test-tmp/`，断言后清理。
@MainActor
final class OffscreenRenderTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try UITestSupport.makeTempDirectory("snapshot")
    }

    override func tearDownWithError() throws {
        UITestSupport.removeQuietly(scratch)
    }

    private func makeModel(withLayer: Bool = false) throws -> StudioModel {
        let recent = RecentProjectStore(fileURL: scratch.appendingPathComponent("recent.json"))
        let model = StudioModel(recentStore: recent)
        if withLayer {
            let imageURL = try UITestSupport.writePNG(
                UITestSupport.verticalHalves(width: 128, height: 128),
                named: "snapshot-layer.png",
                in: scratch
            )
            _ = try model.addLayer(imageURL: imageURL)
            model.project.name = "快照工程"
        }
        return model
    }

    private func uniqueColourCount(_ image: RasterImage) -> Int {
        var colours = Set<UInt32>()
        for y in stride(from: 0, to: image.height, by: 8) {
            for x in stride(from: 0, to: image.width, by: 8) {
                let offset = (y * image.width + x) * 4
                let packed = UInt32(image.pixels[offset]) << 16
                    | UInt32(image.pixels[offset + 1]) << 8
                    | UInt32(image.pixels[offset + 2])
                colours.insert(packed)
            }
        }
        return colours.count
    }

    private func renderAndAssert<Content: View>(
        _ view: Content,
        size: CGSize,
        name: String
    ) throws -> RasterImage {
        let url = scratch.appendingPathComponent("\(name).png")
        try OffscreenRenderer.writePNG(view, size: size, to: url)

        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 1_000, "\(name).png 太小，可能渲染成空图")
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        let image = try RasterImage.load(contentsOf: url)
        XCTAssertEqual(image.width, Int(size.width))
        XCTAssertEqual(image.height, Int(size.height))
        XCTAssertGreaterThan(uniqueColourCount(image), 3, "\(name) 看起来是纯色空图")
        return image
    }

    // MARK: - 必测：主页 + 设计页

    func testRenderHomePage() throws {
        let model = try makeModel()
        _ = try renderAndAssert(
            HomeView(model: model, scrollable: false),
            size: CGSize(width: 1200, height: 800),
            name: "home"
        )
        XCTAssertEqual(model.page, .home)
    }

    func testRenderDesignPageWithLayer() throws {
        let model = try makeModel(withLayer: true)
        _ = try renderAndAssert(
            DesignView(model: model),
            size: CGSize(width: 1200, height: 800),
            name: "design"
        )
        XCTAssertEqual(model.project.layers.count, 1)
        XCTAssertNotNil(model.composedPreview)
    }

    func testRenderDesignPageWithoutLayer() throws {
        let model = try makeModel()
        _ = try renderAndAssert(
            DesignView(model: model),
            size: CGSize(width: 1000, height: 700),
            name: "design-empty"
        )
    }

    // MARK: - 其余四个页面也跑一遍离屏渲染

    func testRenderPreviewPage() throws {
        let model = try makeModel(withLayer: true)
        model.navigate(to: .preview)
        _ = try renderAndAssert(
            PreviewPageView(model: model),
            size: CGSize(width: 1100, height: 720),
            name: "preview-page"
        )
    }

    func testRenderExportPage() throws {
        let model = try makeModel()
        model.navigate(to: .export)
        _ = try renderAndAssert(
            ExportView(model: model, scrollable: false),
            size: CGSize(width: 1100, height: 720),
            name: "export-page"
        )
    }

    func testRenderBurnPageWithMockBurner() throws {
        let recent = RecentProjectStore(fileURL: scratch.appendingPathComponent("recent.json"))
        let model = StudioModel(recentStore: recent, burnService: MockBurnAdapter())
        model.refreshPreview()
        _ = try renderAndAssert(
            BurnView(model: model, scrollable: false),
            size: CGSize(width: 1100, height: 720),
            name: "burn-page"
        )
    }

    func testRenderCalibrationPage() throws {
        let model = try makeModel()
        model.navigate(to: .calibration)
        _ = try renderAndAssert(
            CalibrationView(model: model, scrollable: false),
            size: CGSize(width: 1100, height: 720),
            name: "calibration-page"
        )
    }

    /// 标定页：已导入照片（第一步，控制点可拖）。
    func testRenderCalibrationPageWithPhoto() throws {
        let model = try makeCalibrationModel(stage: .photo)
        _ = try renderAndAssert(
            CalibrationView(model: model, scrollable: false),
            size: CGSize(width: 1240, height: 800),
            name: "calibration-photo"
        )
    }

    /// 标定页：矫正已确认、已描点（第二步，含预测/图例）。
    func testRenderCalibrationPageWithTrace() throws {
        let model = try makeCalibrationModel(stage: .trace)
        _ = try renderAndAssert(
            CalibrationView(model: model, scrollable: false),
            size: CGSize(width: 1240, height: 800),
            name: "calibration-trace"
        )
    }

    private enum CalibrationStage {
        case photo
        case trace
    }

    private func makeCalibrationModel(stage: CalibrationStage) throws -> StudioModel {
        var project = UITestSupport.sampleProject(family: .dvd)
        project.name = "标定快照"
        project.geometry = UITestSupport.calibrationGeometry()
        let model = StudioModel(
            project: project,
            recentStore: RecentProjectStore(fileURL: scratch.appendingPathComponent("recent.json")),
            burnService: MockBurnAdapter()
        )
        let generation = CalibrationGenerationSnapshot(
            geometry: project.geometry,
            tone: project.effectiveTone,
            cdInterleave: false
        )
        try model.calibration.loadSession(CalibrationSession(generation: generation))
        try model.calibration.importPhoto(UITestSupport.syntheticDiscPhoto(size: 256))
        if stage == .trace {
            try model.calibration.rectify()
            model.calibration.confirmRectification()
            for radius in stride(from: 27.0, through: 38.0, by: 1.5) {
                model.calibration.addTracePoint(CalibrationPoint(xMm: radius, yMm: 0))
            }
        }
        return model
    }

    func testRenderMainWindowShell() throws {
        let model = try makeModel(withLayer: true)
        model.navigate(to: .design)
        _ = try renderAndAssert(
            MainWindowView(model: model),
            size: CGSize(width: 1280, height: 800),
            name: "main-window"
        )
    }

    // MARK: - 渲染器本身

    func testSnapshotScale() throws {
        let image = try OffscreenRenderer.raster(
            Text("小蓝鲸"),
            size: CGSize(width: 100, height: 50),
            scale: 2
        )
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 100)
    }

    func testInvalidSizeThrows() {
        XCTAssertThrowsError(try OffscreenRenderer.raster(
            Text("x"),
            size: CGSize(width: 0, height: 10)
        ))
    }

    func testSnapshotsWrittenAndCleanedUp() throws {
        let url = scratch.appendingPathComponent("cleanup-check.png")
        try OffscreenRenderer.writePNG(Text("临时"), size: CGSize(width: 64, height: 64), to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        UITestSupport.removeQuietly(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
