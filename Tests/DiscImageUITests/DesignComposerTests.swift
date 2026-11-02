import DiscImageCore
import DiscImageUI
import XCTest

/// 设计合成：mm 画布 → 8192/2048 px 合成图。
final class DesignComposerTests: XCTestCase {
    func testBaseSizeFitsLongestEdgeToContentDiameter() {
        let landscape = DesignComposer.baseSizeMm(
            pixelWidth: 2000, pixelHeight: 1000, canvasOuterRadiusMm: 57.5
        )
        XCTAssertEqual(landscape.width, 115, accuracy: 1e-9)
        XCTAssertEqual(landscape.height, 57.5, accuracy: 1e-9)

        let portrait = DesignComposer.baseSizeMm(
            pixelWidth: 1000, pixelHeight: 2000, canvasOuterRadiusMm: 58
        )
        XCTAssertEqual(portrait.height, 116, accuracy: 1e-9)
        XCTAssertEqual(portrait.width, 58, accuracy: 1e-9)

        let zero = DesignComposer.baseSizeMm(pixelWidth: 0, pixelHeight: 100, canvasOuterRadiusMm: 57.5)
        XCTAssertEqual(zero, .zero)
    }

    func testEmptyDesignComposesTransparentCanvas() throws {
        let image = try DesignComposer.compose(
            layers: [],
            layerImages: [:],
            canvasOuterRadiusMm: 57.5,
            outputSize: 64
        )
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 64)
        XCTAssertEqual(image.pixels.count, 64 * 64 * 4)
        XCTAssertTrue(image.pixels.enumerated().allSatisfy { $0.offset % 4 == 3 ? $0.element == 0 : true })
    }

    func testLayerOrientationIsNotFlipped() throws {
        let raster = UITestSupport.verticalHalves(width: 64, height: 64)
        let layer = DesignLayer(name: "竖条", imagePath: "/tmp/v.png")
        let image = try DesignComposer.compose(
            layers: [layer],
            layerImages: [layer.id: raster],
            canvasOuterRadiusMm: 57.5,
            outputSize: 100
        )

        // 左半白、右半黑；上下方向不翻转用横条图单独验证。
        XCTAssertGreaterThan(image.luminance(x: 15, y: 50), 200, "左侧应为白")
        XCTAssertLessThan(image.luminance(x: 85, y: 50), 60, "右侧应为黑")

        let horizontal = UITestSupport.horizontalHalves(width: 64, height: 64)
        let horizontalLayer = DesignLayer(name: "横条", imagePath: "/tmp/h.png")
        let flippedCheck = try DesignComposer.compose(
            layers: [horizontalLayer],
            layerImages: [horizontalLayer.id: horizontal],
            canvasOuterRadiusMm: 57.5,
            outputSize: 100
        )
        XCTAssertGreaterThan(flippedCheck.luminance(x: 50, y: 10), 200, "上方应为白（不能被上下翻转）")
        XCTAssertLessThan(flippedCheck.luminance(x: 50, y: 90), 60, "下方应为黑")
    }

    func testTranslationMovesLayerInMillimetres() throws {
        let raster = UITestSupport.verticalHalves(width: 64, height: 64)
        // 画布总宽 115 mm；右移 40 mm 后，左侧约 17.5 mm 的区域应露出透明背景。
        let layer = DesignLayer(
            name: "右移", imagePath: "/tmp/v.png",
            translateXMm: 40, translateYMm: 0, rotationDeg: 0, scale: 1
        )
        let image = try DesignComposer.compose(
            layers: [layer],
            layerImages: [layer.id: raster],
            canvasOuterRadiusMm: 57.5,
            outputSize: 100
        )
        XCTAssertEqual(image.pixels[(50 * 100 + 3) * 4 + 3], 0, "左边缘应被移出画布（透明）")
        XCTAssertGreaterThan(image.luminance(x: 45, y: 50), 200, "画布中部仍是白")
    }

    func testVisibilityAndScale() throws {
        let raster = UITestSupport.gray(width: 64, height: 64, value: 255)
        var layer = DesignLayer(name: "隐藏", imagePath: "/tmp/g.png", visible: false)
        let hidden = try DesignComposer.compose(
            layers: [layer],
            layerImages: [layer.id: raster],
            canvasOuterRadiusMm: 57.5,
            outputSize: 32
        )
        XCTAssertEqual(hidden.pixels[3], 0, "隐藏图层不参与合成")

        layer.visible = true
        layer.scale = 0.25
        let small = try DesignComposer.compose(
            layers: [layer],
            layerImages: [layer.id: raster],
            canvasOuterRadiusMm: 57.5,
            outputSize: 100
        )
        XCTAssertEqual(small.pixels[(50 * 100 + 2) * 4 + 3], 0, "缩小到 25% 后边缘应是透明")
        XCTAssertGreaterThan(small.luminance(x: 50, y: 50), 250, "中心仍是白")
    }

    func testRotation90MovesLeftHalfToTop() throws {
        let raster = UITestSupport.verticalHalves(width: 64, height: 64)
        let layer = DesignLayer(
            name: "旋转", imagePath: "/tmp/v.png",
            translateXMm: 0, translateYMm: 0, rotationDeg: 90, scale: 1
        )
        let image = try DesignComposer.compose(
            layers: [layer],
            layerImages: [layer.id: raster],
            canvasOuterRadiusMm: 57.5,
            outputSize: 100
        )
        // 顺时针 90°：左半（白）转到上方。
        XCTAssertGreaterThan(image.luminance(x: 50, y: 20), 200)
        XCTAssertLessThan(image.luminance(x: 50, y: 80), 60)
    }

    func testExportWritesReadablePNG() throws {
        let directory = try UITestSupport.makeTempDirectory("compose-export")
        defer { UITestSupport.removeQuietly(directory) }

        let raster = UITestSupport.gray(width: 32, height: 32, value: 128)
        let layer = DesignLayer(name: "灰", imagePath: "/tmp/g.png")
        var project = UITestSupport.sampleProject(family: .cd)
        project.layers = [layer]

        let url = directory.appendingPathComponent("composite.png")
        _ = try DesignComposer.writeCompositePNG(
            project: project,
            layerImages: [layer.id: raster],
            outputSize: 128,
            to: url
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        let loaded = try RasterImage.load(contentsOf: url)
        XCTAssertEqual(loaded.width, 128)
        XCTAssertEqual(loaded.height, 128)
    }

    func testThumbnailBase64IsDecodable() throws {
        let raster = UITestSupport.gray(width: 32, height: 32, value: 200)
        let layer = DesignLayer(name: "缩略图", imagePath: "/tmp/g.png")
        var project = UITestSupport.sampleProject(family: .cd)
        project.layers = [layer]

        let base64 = try XCTUnwrap(DesignComposer.thumbnailBase64(
            project: project,
            layerImages: [layer.id: raster]
        ))
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        let image = try RasterImage.load(data: data)
        XCTAssertEqual(image.width, DesignComposer.thumbnailSize)
        XCTAssertEqual(image.height, DesignComposer.thumbnailSize)

        // 空设计没有缩略图。
        var empty = project
        empty.layers = []
        XCTAssertNil(try DesignComposer.thumbnailBase64(project: empty, layerImages: [:]))
    }

    func testOutputSizeValidation() {
        XCTAssertThrowsError(try DesignComposer.compose(
            layers: [], layerImages: [:], canvasOuterRadiusMm: 57.5, outputSize: 0
        ))
        XCTAssertThrowsError(try DesignComposer.compose(
            layers: [], layerImages: [:], canvasOuterRadiusMm: 0, outputSize: 64
        ))
    }

    func testPublishedSizesMatchSpec() {
        XCTAssertEqual(DesignComposer.exportSize, 8192)
        XCTAssertEqual(DesignComposer.previewSize, 2048)
        XCTAssertEqual(DesignComposer.thumbnailSize, 256)
    }
}
