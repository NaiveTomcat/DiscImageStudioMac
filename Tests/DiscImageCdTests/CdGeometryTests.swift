import DiscImageCore
import Foundation
import XCTest

@testable import DiscImageCd

/// CD 几何与采样：2352 字节扇区、75 扇区/秒、面积线性半径、CLV 螺旋角度、
/// 像素半径投影（HANDOFF §2.1 CD 段与 task-2 第 1 条）。
final class CdGeometryTests: XCTestCase {

    func testCoreConstants() {
        XCTAssertEqual(CdDiscParameters.bytesPerSector, 2_352)
        XCTAssertEqual(CdDiscParameters.sectorsPerSecond, 75)
        XCTAssertEqual(CdDiscParameters.standardLinearVelocityMmPerSecond, 1_200)
        XCTAssertEqual(CdDiscParameters.standardImageOuterRadiusMm, 57.5)
    }

    func testTotalBytesAndDuration() {
        let parameters = CdDiscParameters(sectors: 333_000)   // cd-74
        XCTAssertEqual(parameters.totalBytes, 333_000 * 2_352)
        XCTAssertEqual(parameters.totalTimeSeconds, 4_440, accuracy: 1e-9)   // 74 分钟
        // 2352 = 98 帧 × 24 字节，所以每扇区正好是延迟线帧的整数倍。
        XCTAssertEqual(CdDiscParameters.bytesPerSector % CddaInterleaveTable.bytesPerFrame, 0)
    }

    func testGeometryDerivationUsesDiscGeometryFields() {
        let geometry = CdTestSupport.geometry(sectors: 1_000)
        let parameters = CdDiscParameters(geometry: geometry)
        XCTAssertEqual(parameters.innerRadiusMm, geometry.innerRadiusMm)
        XCTAssertEqual(parameters.outerRadiusMm, geometry.outerRadiusMm)
        XCTAssertEqual(parameters.sectors, geometry.sectors)
        XCTAssertEqual(parameters.linearVelocityMmPerSecond, geometry.linearVelocityMmPerSecond)
        XCTAssertEqual(parameters.startAngleRadians, 0)
        XCTAssertEqual(parameters.imageOuterRadiusMm, 57.5)
    }

    func testRadiusEndpointsAndMonotonicity() {
        let parameters = CdTestSupport.parameters(sectors: 1_000)
        XCTAssertEqual(parameters.radiusFromByte(0), parameters.innerRadiusMm, accuracy: 1e-12)
        XCTAssertEqual(
            parameters.radiusFromByte(parameters.totalBytes),
            parameters.outerRadiusMm,
            accuracy: 1e-12
        )
        XCTAssertLessThan(parameters.radiusFromByte(parameters.totalBytes - 1), parameters.outerRadiusMm)

        var previous = -Double.infinity
        for step in 0...100 {
            let byte = parameters.totalBytes * step / 100
            let radius = parameters.radiusFromByte(byte)
            XCTAssertGreaterThan(radius, previous)
            previous = radius
        }
    }

    func testRadiusIsAreaLinearInByteIndex() {
        // r = sqrt(ri² + f·(ro² − ri²))，f = globalByte / totalBytes
        let parameters = CdTestSupport.parameters(sectors: 1_000)
        for step in 0...16 {
            let fraction = Double(step) / 16.0
            let byte = Int(fraction * Double(parameters.totalBytes))
            let radius = parameters.radiusFromByte(byte)
            let areaFraction = (radius * radius - parameters.innerRadiusMm * parameters.innerRadiusMm)
                / parameters.radiusSquaredRange
            XCTAssertEqual(areaFraction, fraction, accuracy: 1e-9)
        }
    }

    func testThetaFollowsClvSpiralFormula() {
        // θ = θ0 + 2vT/(ro² − ri²)·(r − ri)
        let toggled = CdDiscParameters(
            innerRadiusMm: 24.5,
            outerRadiusMm: 56.8,
            sectors: 333_000,
            startAngleRadians: 0.25
        )
        XCTAssertEqual(toggled.thetaFromRadius(toggled.innerRadiusMm), 0.25, accuracy: 1e-12)
        let expected = 0.25
            + 2.0 * 1200.0 * (333_000.0 / 75.0) / (56.8 * 56.8 - 24.5 * 24.5) * (56.8 - 24.5)
        XCTAssertEqual(toggled.thetaFromRadius(56.8), expected, accuracy: 1e-6)

        // 角度随字节序号单调递增（逆时针、CLV）。
        var previous = -Double.infinity
        for step in 0...100 {
            let byte = toggled.totalBytes * step / 100
            let theta = toggled.polarFromByte(byte).angleRadians
            XCTAssertGreaterThan(theta, previous - 1e-12)
            previous = theta
        }
    }

    func testStartAngleRotatesTheImage() {
        let parameters = CdDiscParameters(sectors: 1_000, startAngleRadians: .pi / 2)
        let point = parameters.imagePointFromByte(0, imageSize: 64)
        // θ0 = 90°、r = ri → 正下方。注意画布 y 轴向下（与源项目的 WPF 位图一致），
        // y = centre + pixelRadius·sin θ，所以 sin 为正是往下走。
        XCTAssertEqual(point.x, 32, accuracy: 1e-9)
        XCTAssertGreaterThan(point.y, 32)
        XCTAssertEqual(
            point.y - 32,
            32.0 * parameters.radiusFromByte(0) / parameters.imageOuterRadiusMm,
            accuracy: 1e-9
        )
    }

    func testImagePointMatchesDiscProjection() {
        // 方形画布上 CD 的投影就是 DiscProjection(canvasSize, 57.5) 的原点映射。
        let parameters = CdTestSupport.parameters(sectors: 2_000)
        let canvasSize = 128
        let projection = DiscProjection(canvasSize: canvasSize, imageOuterRadiusMm: 57.5)
        for byte in [0, 1, 1_000, 50_000, 500_000, parameters.totalBytes - 1] {
            let polar = parameters.polarFromByte(byte)
            let expected = projection.canvasPoint(
                radiusMm: polar.radiusMm,
                angleRadians: polar.angleRadians
            )
            let actual = parameters.imagePointFromByte(byte, imageSize: canvasSize)
            XCTAssertEqual(actual.x, expected.x, accuracy: 1e-9, "字节 \(byte) 的 x")
            XCTAssertEqual(actual.y, expected.y, accuracy: 1e-9, "字节 \(byte) 的 y")
        }
    }

    func testPixelRadiusFormula() {
        // pixelRadius = (size/2)·r / ImageOuterRadiusMm
        let parameters = CdTestSupport.parameters(sectors: 1_000)
        let size = 200
        let radius = parameters.radiusFromByte(parameters.totalBytes / 2)
        let theta = parameters.thetaFromRadius(radius)
        let expectedPixelRadius = Double(size) / 2.0 * radius / parameters.imageOuterRadiusMm
        let point = parameters.imagePointFromByte(parameters.totalBytes / 2, imageSize: size)
        let centre = Double(size) / 2.0
        XCTAssertEqual(point.x, centre + expectedPixelRadius * cos(theta), accuracy: 1e-9)
        XCTAssertEqual(point.y, centre + expectedPixelRadius * sin(theta), accuracy: 1e-9)
    }

    func testNonSquareCanvasUsesShorterSide() {
        let parameters = CdTestSupport.parameters(sectors: 1_000)
        let wide = parameters.imagePointFromByte(0, canvasWidth: 100, canvasHeight: 50)
        // θ = 0 → 正右方，横向半径按短边（50）算。
        XCTAssertEqual(wide.y, 25, accuracy: 1e-9)
        XCTAssertEqual(wide.x, 50 + 25 * parameters.radiusFromByte(0) / 57.5, accuracy: 1e-9)
    }

    // MARK: - 采样

    func testSamplerUsesBilinearForContinuousToneImage() {
        let parameters = CdTestSupport.parameters(sectors: 1_000)
        let image = CdTestSupport.testImage()
        let sampler = CdImageSampler(image: image, parameters: parameters)
        XCTAssertFalse(sampler.isNearestNeighbour)

        // 与直接按 (r, θ) → 像素坐标取双线性亮度一致。
        for byte in [0, 1_234, 100_000, parameters.totalBytes / 3] {
            let point = parameters.imagePointFromByte(byte, canvasWidth: image.width, canvasHeight: image.height)
            let expected = UInt8(min(max(image.luminance(bilinearX: point.x, bilinearY: point.y).rounded(), 0), 255))
            XCTAssertEqual(sampler.gray(atByte: byte), expected, "字节 \(byte)")
        }
    }

    func testSamplerUsesNearestForBinaryImage() {
        let parameters = CdTestSupport.parameters(sectors: 1_000)
        let image = CdTestSupport.binaryImage()
        XCTAssertTrue(image.isOpaqueBinaryGrayscale)
        let sampler = CdImageSampler(image: image, parameters: parameters)
        XCTAssertTrue(sampler.isNearestNeighbour)
        // 黑白图只该产出 0 或 255。
        for step in 0...500 {
            let byte = parameters.totalBytes * step / 500
            let gray = sampler.gray(atByte: byte)
            XCTAssertTrue(gray == 0 || gray == 255, "字节 \(byte) 采到 \(gray)")
        }
    }

    func testSamplerClampsOutOfRangeByteIndices() {
        let parameters = CdTestSupport.parameters(sectors: 1_000)
        let sampler = CdImageSampler(image: CdTestSupport.testImage(), parameters: parameters)
        // 超出整盘 → 按外圈采样；负数 → 按内圈采样（源项目的 Math.Clamp 语义）。
        XCTAssertEqual(
            sampler.gray(atByte: parameters.totalBytes + 10_000),
            sampler.gray(atByte: parameters.totalBytes)
        )
        XCTAssertEqual(sampler.gray(atByte: -1), sampler.gray(atByte: 0))
    }

    // MARK: - 校验

    func testValidateAcceptsStandardDiscs() throws {
        try CdDiscParameters(geometry: DiscPreset.cd80.geometry()).validate()
        try CdDiscParameters(geometry: DiscPreset.cd74.geometry()).validate()
        try CdDiscParameters(geometry: DiscPreset.ritekMedicalAqua.geometry()).validate()
    }

    func testValidateRejectsBadParameters() {
        XCTAssertThrowsError(try CdDiscParameters(innerRadiusMm: 0).validate())
        XCTAssertThrowsError(try CdDiscParameters(innerRadiusMm: 60, outerRadiusMm: 50).validate())
        XCTAssertThrowsError(try CdDiscParameters(sectors: 0).validate())
        XCTAssertThrowsError(try CdDiscParameters(linearVelocityMmPerSecond: 0).validate())
        XCTAssertThrowsError(try CdDiscParameters(imageOuterRadiusMm: 0).validate())
    }
}
