import DiscImageCore
import XCTest

@testable import DiscImageDvd

/// 螺旋几何：等螺距用闭式解，三次轨距用数值节点表。
final class DvdSpiralTests: XCTestCase {
    func testConstantPitchEndpointsAndPitch() throws {
        let geometry = DiscPreset.dvd5_120mm.geometry()
        let spiral = try DvdSpiral(geometry: geometry)
        XCTAssertEqual(spiral.trackLengthMm, Double(geometry.sectors) * 38_688 * 0.0001333, accuracy: 1e-3)
        XCTAssertEqual(spiral.radiusAtArcLength(0), 24.0, accuracy: 1e-9)
        XCTAssertEqual(spiral.radiusAtArcLength(spiral.trackLengthMm), 58.0, accuracy: 1e-6)
        // HANDOFF §2.2 自检值：默认 DVD 反算螺距 ≈ 0.7398 µm（等螺距近似，允许 1 nm 级差）。
        XCTAssertEqual(spiral.pitchMm * 1000, 0.74, accuracy: 1e-3)
        // 总角度 = (ro − ri) / b。
        let end = spiral.atArcLength(spiral.trackLengthMm)
        XCTAssertEqual(end.angleRadians, spiral.totalAngleRadians, accuracy: 1e-9)
    }

    func testRadiusIsMonotone() throws {
        let geometry = DiscPreset.dvd5_120mm.geometry()
        let spiral = try DvdSpiral(geometry: geometry)
        var previousRadius = 0.0
        var previousAngle = 0.0
        for index in 0...500 {
            let arc = spiral.trackLengthMm * Double(index) / 500
            let point = spiral.atArcLength(arc)
            XCTAssertGreaterThanOrEqual(point.radiusMm, previousRadius)
            XCTAssertGreaterThanOrEqual(point.angleRadians, previousAngle)
            XCTAssertGreaterThanOrEqual(point.radiusMm, 24.0 - 1e-9)
            XCTAssertLessThanOrEqual(point.radiusMm, 58.0 + 1e-9)
            previousRadius = point.radiusMm
            previousAngle = point.angleRadians
        }
        XCTAssertEqual(previousRadius, 58.0, accuracy: 1e-6)
    }

    func testSmallGeometryEndpoints() throws {
        let geometry = DiscGeometry(
            family: .dvd,
            innerRadiusMm: 24,
            outerRadiusMm: 58,
            sectors: 96,
            channelBitLengthNm: 133.3
        )
        let spiral = try DvdSpiral(geometry: geometry)
        XCTAssertEqual(spiral.radiusAtArcLength(0), 24, accuracy: 1e-9)
        XCTAssertEqual(spiral.radiusAtArcLength(spiral.trackLengthMm), 58, accuracy: 1e-6)
        XCTAssertGreaterThan(spiral.pitchMm, 0)
    }

    func testCubicPitchPreset() throws {
        let geometry = DiscPreset.verbatimDvdAzo43533.geometry()
        XCTAssertTrue(geometry.hasCubicPitch)
        let spiral = try DvdSpiral(geometry: geometry)
        XCTAssertFalse(spiral.isConstantPitch)
        XCTAssertEqual(spiral.radiusAtArcLength(0), geometry.innerRadiusMm, accuracy: 1e-9)
        XCTAssertEqual(spiral.radiusAtArcLength(spiral.trackLengthMm), geometry.outerRadiusMm, accuracy: 1e-6)

        var previous = 0.0
        for index in 0...100 {
            let arc = spiral.trackLengthMm * Double(index) / 100
            let radius = spiral.radiusAtArcLength(arc)
            XCTAssertGreaterThanOrEqual(radius, previous)
            previous = radius
        }
        // 三次轨距只在实测盘片的 ~1e-5 量级上修正，平均螺距仍应接近 0.74 µm。
        XCTAssertEqual(spiral.pitchMm * 1000, 0.74, accuracy: 0.02)
    }

    func testIncrementalAdvanceMatchesExactArcSolution() throws {
        let geometry = DiscPreset.dvd5_120mm.geometry()
        let spiral = try DvdSpiral(geometry: geometry)
        let offsets = DvdPayloadPainter.channelOffsets
        let bitLength = spiral.channelBitLengthMm

        // 模拟绘图热循环：只在一个 Block 的起点精确求解，其余走增量推进。
        let startArc = Double(offsets[0]) * bitLength
        let start = spiral.atArcLength(startArc)
        var radius = start.radiusMm
        var angle = start.angleRadians
        var previousOffset = offsets[0]
        for index in 1..<offsets.count {
            let deltaArc = Double(offsets[index] - previousOffset) * bitLength
            let step = spiral.advance(radiusMm: radius, deltaArcLengthMm: deltaArc)
            radius = step.radiusMm
            angle += step.deltaAngleRadians
            previousOffset = offsets[index]
        }
        let end = spiral.atArcLength(Double(offsets[offsets.count - 1]) * bitLength)
        // 单个 Block 内累积误差应远小于 1 个通道位（133 nm）。
        XCTAssertEqual(radius, end.radiusMm, accuracy: 1e-6, "增量推进的半径偏差过大")
        XCTAssertEqual(angle, end.angleRadians, accuracy: 1e-7, "增量推进的角度偏差过大")
    }

    func testRejectsWrongFamilyOrTooShortTrack() {
        var geometry = DiscPreset.dvd5_120mm.geometry()
        geometry.family = .cd
        XCTAssertThrowsError(try DvdSpiral(geometry: geometry))
        // DVD 几何校验：扇区数必须是 16 的倍数。
        var wrongAlignment = geometry
        wrongAlignment.family = .dvd
        wrongAlignment.sectors = 17
        XCTAssertThrowsError(try DvdSpiral(geometry: wrongAlignment))
    }
}
