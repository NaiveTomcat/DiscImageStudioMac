import XCTest
@testable import DiscImageCore

/// 点数/覆盖不足、偏离过大、搜索边界、圈偏移歧义等判定。
final class CalibrationFitBehaviourTests: XCTestCase {
    private let generation = CalibrationTestSupport.dvdGeometry(inner: 24, outer: 58)

    private func fit(
        _ points: [CalibrationPoint],
        options: CalibrationFitOptions? = nil,
        generation: DiscGeometry? = nil
    ) throws -> CalibrationFitResult {
        try CalibrationCrossFitter.fit(
            session: CalibrationTestSupport.session(generation: generation ?? self.generation),
            points: points,
            options: options
        )
    }

    // MARK: 点数 / 覆盖

    func testTooFewPointsIsRejected() throws {
        let actual = CalibrationTestSupport.dvdGeometry(inner: 24.0012, outer: 57.9993)
        let points = try CalibrationTestSupport.syntheticTrace(
            generation: generation,
            actual: actual,
            count: 4
        )
        let result = try fit(points)
        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.best)
        XCTAssertFalse(result.isApplicable)
        XCTAssertTrue(result.warnings.contains { $0.contains("至少标出 6 个点") })
    }

    func testNarrowCoverageIsRejected() throws {
        let actual = CalibrationTestSupport.dvdGeometry(inner: 24.0012, outer: 57.9993)
        let points = try CalibrationTestSupport.syntheticTrace(
            generation: generation,
            actual: actual,
            progressRange: 0.45...0.55,
            count: 24
        )
        let result = try fit(points)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.warnings.contains { $0.contains("覆盖范围太窄") })
    }

    func testModerateCoverageStillWarns() throws {
        let actual = CalibrationTestSupport.dvdGeometry(inner: 24.0012, outer: 57.9993)
        let points = try CalibrationTestSupport.syntheticTrace(
            generation: generation,
            actual: actual,
            progressRange: 0.2...0.75,
            count: 40
        )
        let result = try fit(points)
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.warnings.contains { $0.contains("补充更靠内、外") })
    }

    func testCubicPitchNeedsTwelveRadialLevels() throws {
        let actual = CalibrationTestSupport.dvdGeometry(
            inner: 24.0012,
            outer: 57.9993,
            coefficients: (linear: 2e-4, quadratic: -2.6e-4, cubic: 1.8e-4)
        )
        let points = try CalibrationTestSupport.syntheticTrace(
            generation: generation,
            actual: actual,
            count: 10
        )
        let result = try fit(points)
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.warnings.contains { $0.contains("至少 12") })
        XCTAssertEqual(result.best?.pitchLinear, 0, "点数不足时应保留原轨距系数")
    }

    func testCubicPitchNeedsSixtyPercentCoverage() throws {
        let actual = CalibrationTestSupport.dvdGeometry(
            inner: 24.0012,
            outer: 57.9993,
            coefficients: (linear: 2e-4, quadratic: -2.6e-4, cubic: 1.8e-4)
        )
        let points = try CalibrationTestSupport.syntheticTrace(
            generation: generation,
            actual: actual,
            progressRange: 0.3...0.65,
            count: 24
        )
        let result = try fit(points)
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.warnings.contains { $0.contains("60%") })
    }

    // MARK: 偏离 / 不可应用

    func testOutlierPointMakesCandidateInapplicable() throws {
        let actual = CalibrationTestSupport.dvdGeometry(inner: 24.0012, outer: 57.9993)
        var points = try CalibrationTestSupport.syntheticTrace(
            generation: generation,
            actual: actual,
            count: 65
        )
        // 最外圈的最后一个点沿半径外移 3 mm，模拟一次明显误点（半径顺序不变，便于单独观察残差）。
        let index = points.count - 1
        let radius = points[index].radiusMm + 3
        let angle = points[index].angleRadians
        points[index] = CalibrationPoint(xMm: radius * cos(angle), yMm: radius * sin(angle))

        // 关掉三次轨距，让这条误点不能被多出来的形状自由度吸收。
        var options = CalibrationFitOptions()
        options.fitDvdPitch = false
        let result = try fit(points, options: options)
        XCTAssertTrue(result.succeeded)
        let best = try XCTUnwrap(result.best)
        XCTAssertGreaterThan(best.maxErrorMm, CalibrationFitCandidate.applicableMaxErrorMm)
        XCTAssertEqual(best.outlierCount, 1)
        XCTAssertFalse(result.isApplicable)
        XCTAssertNotNil(result.rejectionReason)
    }

    func testPointJumpingToAnotherArmIsNotApplicable() throws {
        let actual = CalibrationTestSupport.dvdGeometry(inner: 24.0012, outer: 57.9993)
        var points = try CalibrationTestSupport.syntheticTrace(
            generation: generation,
            actual: actual,
            count: 65
        )
        // 第 32 个点跳到另一条十字臂（同半径、转角 +90°）。
        let index = 32
        let radius = points[index].radiusMm
        let angle = points[index].angleRadians + .pi / 2
        points[index] = CalibrationPoint(xMm: radius * cos(angle), yMm: radius * sin(angle))

        let result = try fit(points)
        XCTAssertFalse(result.isApplicable, "单点跳到别的臂应导致不可应用：\(result.warnings)")
    }

    // MARK: 顺序 / 歧义

    func testReversedOrderIsRejected() throws {
        let actual = CalibrationTestSupport.dvdGeometry(inner: 24.0012, outer: 57.9993)
        let points = try CalibrationTestSupport.syntheticTrace(
            generation: generation,
            actual: actual,
            count: 40
        )
        let result = try fit(points.reversed())
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.warnings.contains { $0.contains("向内回退") })
    }

    func testAdjacentHalfTurnIsRejected() throws {
        let actual = CalibrationTestSupport.dvdGeometry(inner: 24.0012, outer: 57.9993)
        var points = try CalibrationTestSupport.syntheticTrace(
            generation: generation,
            actual: actual,
            count: 65
        )
        let index = 32
        let radius = points[index].radiusMm
        let angle = points[index].angleRadians + .pi
        points[index] = CalibrationPoint(xMm: radius * cos(angle), yMm: radius * sin(angle))

        let result = try fit(points)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.warnings.contains { $0.contains("接近半圈") })
    }

    /// 整条 trace 只有一个整数圈偏移（这里是整体转角）时应能收敛：半径不随整体转角变化。
    func testWholeTraceRotationOffsetIsResolved() throws {
        let actual = CalibrationTestSupport.dvdGeometry(inner: 24.0012, outer: 57.9993)
        let rotation = 2.0
        let points = try CalibrationTestSupport.syntheticTrace(
            generation: generation,
            actual: actual,
            count: 65,
            rotation: rotation
        )
        let result = try fit(points)
        let best = try XCTUnwrap(result.best)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(best.innerRadiusMm, 24.0012, accuracy: 1e-3)
        XCTAssertEqual(best.outerRadiusMm, 57.9993, accuracy: 1e-3)
        // 整体转角作为独立量返回（归一化到 (−π, π]）。
        XCTAssertEqual(best.rotationRadians, rotation, accuracy: 1e-3)
    }

    // MARK: 搜索范围

    func testSearchRangeExpandsAutomaticallyWhenBoundaryLimited() throws {
        let actual = CalibrationTestSupport.dvdGeometry(inner: 24.0012, outer: 57.9993)
        let points = try CalibrationTestSupport.syntheticTrace(
            generation: generation,
            actual: actual,
            count: 65
        )
        // 初始范围 ±0.0005 装不下 0.0012 的偏差 → 自动扩到默认的 ±0.02。
        var options = CalibrationFitOptions()
        options.searchRangeMm = 0.0005
        let result = try fit(points, options: options)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.searchRangeMm?.0 ?? .nan, -0.02, accuracy: 1e-12)
        XCTAssertEqual(result.searchRangeMm?.1 ?? .nan, 0.02, accuracy: 1e-12)
        XCTAssertTrue(result.warnings.contains { $0.contains("已自动扩大") })
        XCTAssertEqual(result.best?.innerRadiusMm ?? .nan, 24.0012, accuracy: 1e-3)
        XCTAssertEqual(result.best?.outerRadiusMm ?? .nan, 57.9993, accuracy: 1e-3)
        XCTAssertFalse(result.boundaryLimited)
    }

    func testManualRangeStaysBoundaryLimited() throws {
        let actual = CalibrationTestSupport.dvdGeometry(inner: 24.0012, outer: 57.9993)
        let points = try CalibrationTestSupport.syntheticTrace(
            generation: generation,
            actual: actual,
            count: 65
        )
        var options = CalibrationFitOptions()
        options.searchRangeMm = 0.0005
        options.autoRange = false
        let result = try fit(points, options: options)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.searchRangeMm?.1 ?? .nan, 0.0005, accuracy: 1e-12)
        XCTAssertTrue(result.boundaryLimited)
        XCTAssertTrue(result.warnings.contains { $0.contains("靠近搜索边界") })
    }
}
