import CryptoKit
import XCTest
@testable import DiscImageCore

/// 图案生成：原图指纹、缩放/裁切映射、PNG 导出。
final class CalibrationPatternTests: XCTestCase {
    private let dvd = CalibrationTestSupport.dvdGeometry(inner: 24, outer: 58)

    // MARK: 原图

    func testReferenceImageMatchesKnownFingerprint() throws {
        let image = try CalibrationPattern.referenceImage()
        XCTAssertEqual(image.width, 2400)
        XCTAssertEqual(image.height, 2400)
        // 圆心处是十字线交会：黑。
        XCTAssertEqual(image.luminance(x: 1199, y: 1199), 0, accuracy: 0.5)
        // 角落是白底。
        XCTAssertEqual(image.luminance(x: 0, y: 0), 255, accuracy: 0.5)
        // 原图三通道相同，灰度缓冲区应与资源 README 的固定指纹一致。
        let gray = try CalibrationPattern.grayPixels()
        XCTAssertEqual(gray.count, 2400 * 2400)
        let digest = SHA256.hash(data: Data(gray)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, CalibrationPattern.graySha256)
        XCTAssertEqual(CalibrationPattern.ringRadiiPixels.count, 9)
    }

    // MARK: 坐标映射

    func testMillimetresPerPixelFollowsEncoderConvention() {
        // DVD 用像素中心基 1199.5；CD/BD 用 1200（与上游一致）。
        XCTAssertEqual(
            CalibrationPattern.millimetresPerPixel(outerRadiusMm: 58, family: .dvd),
            58 / 1199.5,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            CalibrationPattern.millimetresPerPixel(outerRadiusMm: 56.8, family: .cd),
            56.8 / 1200,
            accuracy: 1e-12
        )
        let disc = CalibrationPattern.pixelToDisc(x: 1199.5, y: 1199.5, outerRadiusMm: 58, family: .dvd)
        XCTAssertEqual(disc.xMm, 0, accuracy: 1e-12)
        XCTAssertEqual(disc.yMm, 0, accuracy: 1e-12)
        // 外半径正好对应画布半宽。
        let edge = CalibrationPattern.pixelToDisc(x: 2399, y: 1199.5, outerRadiusMm: 58, family: .dvd)
        XCTAssertEqual(edge.xMm, 58, accuracy: 1e-12)
        XCTAssertEqual(edge.yMm, 0, accuracy: 1e-12)
    }

    func testSampleScalesRingsByGenerationOuterRadius() {
        // 原图第 7 条圆的参考半径是 1050 像素；按外半径 58 mm 缩放后 ≈ 50.77 mm。
        let millimetresPerPixel = CalibrationPattern.millimetresPerPixel(outerRadiusMm: 58, family: .dvd)
        let ringRadius = 1050 * millimetresPerPixel
        let diagonal = ringRadius / 2.0.squareRoot()
        XCTAssertEqual(
            CalibrationPattern.sample(xMm: diagonal, yMm: diagonal, geometry: dvd),
            0,
            "第 7 条同心圆应为黑"
        )
        // 两条圆之间是白底。
        let between = 1010 * millimetresPerPixel / 2.0.squareRoot()
        XCTAssertEqual(
            CalibrationPattern.sample(xMm: between, yMm: between, geometry: dvd),
            255,
            "圆之间的空白应为白"
        )
        // 内半径以内被裁掉。
        XCTAssertEqual(CalibrationPattern.sample(xMm: 5, yMm: 5, geometry: dvd), 255)
        // 外半径以外被裁掉。
        XCTAssertEqual(CalibrationPattern.sample(xMm: 59, yMm: 0, geometry: dvd), 255)
        // 缩小外半径时，同一条圆的毫米半径同比缩小。
        let small = CalibrationTestSupport.dvdGeometry(inner: 24, outer: 40)
        let smallRing = 1050 * CalibrationPattern.millimetresPerPixel(outerRadiusMm: 40, family: .dvd)
        let smallDiagonal = smallRing / 2.0.squareRoot()
        XCTAssertEqual(CalibrationPattern.sample(xMm: smallDiagonal, yMm: smallDiagonal, geometry: small), 0)
    }

    func testImageClipsInnerRadiusAndKeepsGreyEdges() throws {
        let image = try CalibrationPattern.image(
            geometry: dvd,
            drawingStartSector: 0,
            drawingEndSectorExclusive: 0,
            canvasSize: 480
        )
        XCTAssertEqual(image.width, 480)
        XCTAssertEqual(image.height, 480)
        let millimetresPerPixel = CalibrationPattern.millimetresPerPixel(outerRadiusMm: 58, family: .dvd)
        let scale = 480.0 / 2400.0
        let centre = 1199.5 * scale
        let pixelPerMm = 1 / (millimetresPerPixel / scale)

        func luminance(radiusMm: Double, angle: Double = .pi / 4) throws -> Double {
            let x = centre + radiusMm * pixelPerMm * cos(angle)
            let y = centre + radiusMm * pixelPerMm * sin(angle)
            return image.luminance(bilinearX: x, bilinearY: y)
        }
        // 内半径（24 mm）以内是白底（中心孔被裁掉）。
        XCTAssertGreaterThan(try luminance(radiusMm: 20), 250)
        // 内半径之外的第 3 条圆（730 px ≈ 35.3 mm）应能看到黑线。
        let ringRadius = 730 * CalibrationPattern.millimetresPerPixel(outerRadiusMm: 58, family: .dvd)
        XCTAssertLessThan(try luminance(radiusMm: ringRadius), 40)
        // 外半径之外是白底。
        XCTAssertGreaterThan(try luminance(radiusMm: 59), 250)
        // 灰阶边缘：裁切边界与斜线边缘保留中间灰，而不是硬二值。
        var intermediate = 0
        for offset in stride(from: 0, to: image.pixels.count, by: 4) {
            let value = image.pixels[offset]
            if value > 8 && value < 247 { intermediate += 1 }
        }
        XCTAssertGreaterThan(intermediate, 0, "缩放后的图案应保留原图的灰阶边缘")
    }

    func testWritePNGExports2400Square() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calibration-pattern-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("target.png")
        try CalibrationPattern.writePNG(to: url, geometry: dvd)
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 10_000)
        let reloaded = try RasterImage.load(contentsOf: url)
        XCTAssertEqual(reloaded.width, 2400)
        XCTAssertEqual(reloaded.height, 2400)
        // 不加入预览背景边距：四个角仍是白底而不是 120 mm 盘面背景。
        XCTAssertEqual(reloaded.luminance(x: 0, y: 0), 255, accuracy: 0.5)
    }

    func testBluRayDrawingRangeFallsBackToDataArea() {
        let generation = CalibrationGenerationSnapshot(geometry: CalibrationTestSupport.bdGeometry())
        // 未指定绘图扇区时，图案覆盖完整数据区。
        XCTAssertEqual(generation.drawingInnerRadiusMm, 24, accuracy: 1e-9)
        XCTAssertEqual(generation.drawingOuterRadiusMm, 58, accuracy: 1e-9)
    }
}
