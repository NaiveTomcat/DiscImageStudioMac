import DiscImageCore
import DiscImageUI
import XCTest

/// 盘面预览：DiscProjection 极坐标渲染 + 文件区黄色标记。
final class DiscPreviewRendererTests: XCTestCase {
    private let size = 128

    private func pixel(_ image: RasterImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let offset = (y * image.width + x) * 4
        return (image.pixels[offset], image.pixels[offset + 1], image.pixels[offset + 2], image.pixels[offset + 3])
    }

    func testBlankDiscShowsHubAndBlackDataArea() throws {
        let project = UITestSupport.sampleProject(family: .cd)
        let image = try DiscPreviewRenderer.render(
            project: project,
            sourceImage: nil,
            fileRegion: nil,
            outputSize: size
        )
        XCTAssertEqual(image.width, size)
        XCTAssertEqual(image.height, size)

        // 中心孔：深灰且不透明。
        let hub = pixel(image, x: size / 2, y: size / 2)
        XCTAssertEqual(hub.r, DiscPreviewRenderer.hubRGB.0)
        XCTAssertEqual(hub.a, 255)

        // 数据区中部（半径约 27 mm）：没有设计图时是黑色。
        let projection = DiscProjection(canvasSize: size, imageOuterRadiusMm: project.canvasOuterRadiusMm)
        let midRadiusPixels = Int((27.0 / projection.mmPerPixel).rounded())
        let data = pixel(image, x: size / 2 + midRadiusPixels, y: size / 2)
        XCTAssertEqual(data.r, DiscPreviewRenderer.blackRGB.0)
        XCTAssertEqual(data.a, 255)

        // 盘面外（角落，半径 > 58 mm）：透明。
        let corner = pixel(image, x: size - 1, y: size - 1)
        XCTAssertEqual(corner.a, 0)
    }

    func testWhiteSourceBecomesWhiteInDataArea() throws {
        let tone = ToneProfile(ditherStrength: 0, levels: 2)
        var project = UITestSupport.sampleProject(family: .dvd)
        project.tone = tone
        let source = UITestSupport.gray(width: 64, height: 64, value: 255)

        let image = try DiscPreviewRenderer.render(
            project: project,
            sourceImage: source,
            fileRegion: nil,
            outputSize: size
        )
        let projection = DiscProjection(canvasSize: size, imageOuterRadiusMm: project.canvasOuterRadiusMm)
        let radiusPixels = Int((40.0 / projection.mmPerPixel).rounded())
        let sample = pixel(image, x: size / 2 + radiusPixels, y: size / 2)
        XCTAssertEqual(sample.r, DiscPreviewRenderer.whiteRGB.0)
        XCTAssertEqual(sample.a, 255)
    }

    func testFileRegionIsPaintedYellow() throws {
        let project = UITestSupport.sampleProject(family: .cd)
        let fileRegion = FileRegion.estimated(
            dataByteCount: 80_000_000,
            geometry: project.geometry,
            atOuterRing: false
        )
        let region = try XCTUnwrap(fileRegion)
        XCTAssertFalse(region.isEmpty)
        XCTAssertEqual(region.startSector, 0, accuracy: 1e-6)

        let image = try DiscPreviewRenderer.render(
            project: project,
            sourceImage: nil,
            fileRegion: region,
            outputSize: 160
        )
        var yellowCount = 0
        for y in stride(from: 0, to: image.height, by: 2) {
            for x in stride(from: 0, to: image.width, by: 2) {
                let colour = pixel(image, x: x, y: y)
                if colour.r == DiscPreviewRenderer.fileRegionRGB.0,
                   colour.g == DiscPreviewRenderer.fileRegionRGB.1,
                   colour.b == DiscPreviewRenderer.fileRegionRGB.2,
                   colour.a == 255 {
                    yellowCount += 1
                }
            }
        }
        XCTAssertGreaterThan(yellowCount, 10, "文件区应出现黄色像素")
    }

    func testFileRegionOuterRingStartsNearOuterRadius() {
        let project = UITestSupport.sampleProject(family: .dvd)
        let inner = FileRegion.estimated(
            dataByteCount: 100_000_000,
            geometry: project.geometry,
            atOuterRing: false
        )
        let outer = FileRegion.estimated(
            dataByteCount: 100_000_000,
            geometry: project.geometry,
            atOuterRing: true
        )
        let innerRegion = inner!
        let outerRegion = outer!
        XCTAssertEqual(outerRegion.endSector, Double(project.geometry.sectors), accuracy: 1e-6)
        XCTAssertGreaterThan(outerRegion.startSector, innerRegion.endSector * 0.9)
        XCTAssertEqual(innerRegion.startSector, 0, accuracy: 1e-6)
    }

    func testFileRegionNilWhenNoBytes() {
        let project = UITestSupport.sampleProject(family: .cd)
        XCTAssertNil(FileRegion.estimated(dataByteCount: 0, geometry: project.geometry, atOuterRing: false))
    }

    func testReadbackModeUsesGrayLevel() throws {
        let project = UITestSupport.sampleProject(family: .cd)
        let source = UITestSupport.gray(width: 64, height: 64, value: 40)

        let image = try DiscPreviewRenderer.render(
            project: project,
            sourceImage: source,
            fileRegion: nil,
            outputSize: 96,
            mode: .readback
        )
        let projection = DiscProjection(canvasSize: 96, imageOuterRadiusMm: project.canvasOuterRadiusMm)
        let radiusPixels = Int((30.0 / projection.mmPerPixel).rounded())
        let sample = pixel(image, x: 48 + radiusPixels, y: 48)
        XCTAssertEqual(sample.r, DiscPreviewRenderer.blackRGB.0)
    }

    func testPNGEncoding() throws {
        let project = UITestSupport.sampleProject(family: .bluRay)
        let data = try DiscPreviewRenderer.pngData(
            project: project,
            sourceImage: nil,
            fileRegion: nil,
            outputSize: 256
        )
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let image = try RasterImage.load(data: data)
        XCTAssertEqual(image.width, 256)
        XCTAssertEqual(image.height, 256)
    }

    func testPreviewSizeIs2048() throws {
        let project = UITestSupport.sampleProject(family: .dvd)
        let image = try DiscPreviewRenderer.previewImage(
            project: project,
            sourceImage: nil,
            fileRegion: nil
        )
        XCTAssertEqual(image.width, DesignComposer.previewSize)
        XCTAssertEqual(image.height, DesignComposer.previewSize)
    }

    func testInvalidOutputSizeThrows() {
        let project = UITestSupport.sampleProject(family: .cd)
        XCTAssertThrowsError(try DiscPreviewRenderer.render(
            project: project,
            sourceImage: nil,
            fileRegion: nil,
            outputSize: 0
        ))
    }
}
