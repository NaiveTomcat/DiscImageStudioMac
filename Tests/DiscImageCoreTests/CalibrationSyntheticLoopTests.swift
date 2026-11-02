import XCTest
@testable import DiscImageCore

/// 合成闭环：已知参数 → 轨道模型生成「照片点」→（可选）单应变换 + 噪声 → 反推。
final class CalibrationSyntheticLoopTests: XCTestCase {
    // MARK: 恒定轨距（DVD / CD / BD）

    func testConstantPitchClosedLoopIsExact() throws {
        let generation = CalibrationTestSupport.dvdGeometry(inner: 24, outer: 58)
        let actual = CalibrationTestSupport.dvdGeometry(inner: 24.0012, outer: 57.9993)
        let points = try CalibrationTestSupport.syntheticTrace(
            generation: generation,
            actual: actual,
            count: 65
        )
        let result = try CalibrationCrossFitter.fit(
            session: CalibrationTestSupport.session(generation: generation),
            points: points
        )
        XCTAssertTrue(result.succeeded)
        let best = try XCTUnwrap(result.best)
        XCTAssertLessThan(best.rmsErrorMm, 1e-5, "无噪声合成闭环应几乎精确")
        XCTAssertEqual(best.innerRadiusMm, 24.0012, accuracy: 1e-4)
        XCTAssertEqual(best.outerRadiusMm, 57.9993, accuracy: 1e-4)
        XCTAssertTrue(result.isApplicable)
        // 生成参数没有三次系数，半径拟合阶段不应凭空造出系数。
        XCTAssertEqual(best.pitchLinear, 0)
        XCTAssertEqual(result.searchRangeMm?.0 ?? .nan, -0.02, accuracy: 1e-12)
    }

    func testCubicPitchClosedLoopRecoversCoefficients() throws {
        let generation = CalibrationTestSupport.dvdGeometry(inner: 24, outer: 58)
        let expected = (linear: 2e-4, quadratic: -2.6e-4, cubic: 1.8e-4)
        let actual = CalibrationTestSupport.dvdGeometry(
            inner: 24.0012,
            outer: 57.9993,
            coefficients: expected
        )
        let points = try CalibrationTestSupport.syntheticTrace(
            generation: generation,
            actual: actual,
            count: 65
        )
        let result = try CalibrationCrossFitter.fit(
            session: CalibrationTestSupport.session(generation: generation),
            points: points
        )
        let best = try XCTUnwrap(result.best)
        XCTAssertTrue(result.succeeded)
        XCTAssertLessThan(best.rmsErrorMm, 1e-5)
        XCTAssertEqual(best.innerRadiusMm, 24.0012, accuracy: 1e-4)
        XCTAssertEqual(best.outerRadiusMm, 57.9993, accuracy: 1e-4)
        XCTAssertEqual(best.pitchLinear, expected.linear, accuracy: 1e-6)
        XCTAssertEqual(best.pitchQuadratic, expected.quadratic, accuracy: 1e-6)
        XCTAssertEqual(best.pitchCubic, expected.cubic, accuracy: 1e-6)
        XCTAssertTrue(result.isApplicable)
        // 单条曲线不能宣称参数唯一。
        XCTAssertTrue(result.warnings.contains { $0.contains("不表示参数唯一") })
    }

    func testCdClosedLoopRecoversRadii() throws {
        let generation = CalibrationTestSupport.cdGeometry(inner: 24.5, outer: 56.8)
        let actual = CalibrationTestSupport.cdGeometry(inner: 24.52, outer: 56.78)
        let points = try CalibrationTestSupport.syntheticTrace(
            generation: generation,
            actual: actual,
            count: 40
        )
        let result = try CalibrationCrossFitter.fit(
            session: CalibrationTestSupport.session(generation: generation),
            points: points
        )
        let best = try XCTUnwrap(result.best)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(best.innerRadiusMm, 24.52, accuracy: 0.01)
        XCTAssertEqual(best.outerRadiusMm, 56.78, accuracy: 0.01)
        XCTAssertLessThan(best.rmsErrorMm, 1e-3)
    }

    func testBluRayClosedLoopRecoversRadii() throws {
        let generation = CalibrationTestSupport.bdGeometry(inner: 24, outer: 58)
        // 蓝光每毫米圈数远高于 CD/DVD，合成描点必须足够密才能无歧义展开。
        let actual = CalibrationTestSupport.bdGeometry(inner: 24.001, outer: 57.999)
        let points = try CalibrationTestSupport.syntheticTrace(
            generation: generation,
            actual: actual,
            count: 80
        )
        let result = try CalibrationCrossFitter.fit(
            session: CalibrationTestSupport.session(generation: generation),
            points: points
        )
        let best = try XCTUnwrap(result.best)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(best.innerRadiusMm, 24.001, accuracy: 0.005)
        XCTAssertEqual(best.outerRadiusMm, 57.999, accuracy: 0.005)
        XCTAssertLessThan(best.rmsErrorMm, 1e-3)
    }

    // MARK: 全链路（透视 + 噪声）

    func testPerspectiveAndNoiseClosedLoop() throws {
        let generation = CalibrationTestSupport.dvdGeometry(inner: 24, outer: 58)
        let expected = (linear: 2e-4, quadratic: -2.6e-4, cubic: 1.8e-4)
        let actual = CalibrationTestSupport.dvdGeometry(
            inner: 24.0012,
            outer: 57.9993,
            coefficients: expected
        )
        let discPoints = try CalibrationTestSupport.syntheticTrace(
            generation: generation,
            actual: actual,
            count: 65
        )

        let matrix = CalibrationTestSupport.homography()
        let outerPixels = CalibrationTestSupport.map(
            CalibrationTestSupport.circlePoints(radiusMm: 60, count: 24),
            through: matrix,
            pixelNoise: 0.3
        )
        let holePixels = CalibrationTestSupport.map(
            CalibrationTestSupport.circlePoints(radiusMm: 7.5, count: 16),
            through: matrix,
            pixelNoise: 0.3
        )
        let tracePixels = CalibrationTestSupport.map(discPoints, through: matrix, pixelNoise: 0.2)

        let rectified = try CalibrationPhotoRectifier.fit(
            outerEdge: outerPixels,
            centerHole: holePixels,
            discSize: .standard12cm
        )
        XCTAssertTrue(rectified.transform.isValidForDisc(60))
        XCTAssertLessThan(rectified.rmsPixels, 1)

        let discEstimate = tracePixels.map { rectified.transform.sourceToDisc($0) }
        let result = try CalibrationCrossFitter.fit(
            session: CalibrationTestSupport.session(generation: generation),
            points: discEstimate
        )
        let best = try XCTUnwrap(result.best)
        XCTAssertTrue(result.succeeded)
        // 半径误差 < 0.05 mm（验收要求）。
        XCTAssertEqual(best.innerRadiusMm, 24.0012, accuracy: 0.05)
        XCTAssertEqual(best.outerRadiusMm, 57.9993, accuracy: 0.05)
        // 三次系数相对误差 < 20%。
        XCTAssertEqual(best.pitchLinear, expected.linear, accuracy: abs(expected.linear) * 0.2)
        XCTAssertEqual(best.pitchQuadratic, expected.quadratic, accuracy: abs(expected.quadratic) * 0.2)
        XCTAssertEqual(best.pitchCubic, expected.cubic, accuracy: abs(expected.cubic) * 0.2)
        XCTAssertTrue(result.isApplicable, "残差应在可应用门槛内：\(result.warnings)")
    }

    // MARK: 预测叠线

    func testPredictionMatchesSyntheticCurve() throws {
        let generation = CalibrationTestSupport.dvdGeometry(inner: 24, outer: 58)
        let actual = CalibrationTestSupport.dvdGeometry(
            inner: 24.0012,
            outer: 57.9993,
            coefficients: (linear: 2e-4, quadratic: -2.6e-4, cubic: 1.8e-4)
        )
        let rotation = 0.47
        let points = try CalibrationTestSupport.syntheticTrace(
            generation: generation,
            actual: actual,
            count: 65,
            rotation: rotation
        )
        let session = CalibrationTestSupport.session(generation: generation)
        let result = try CalibrationCrossFitter.fit(session: session, points: points)
        let best = try XCTUnwrap(result.best)

        // 用反推参数预测曲线，应与合成描点重合（同一物理模型）。
        let radii = points.map(\.radiusMm)
        let predicted = try CalibrationCrossPrediction.curve(
            session: session,
            candidate: best,
            radiiMm: radii
        )
        XCTAssertEqual(predicted.count, radii.count)
        for (index, actualPoint) in points.enumerated() {
            XCTAssertLessThan(
                predicted[index].distance(to: actualPoint),
                5e-3,
                "预测点 \(index) 应贴合合成曲线"
            )
        }

        // 完整叠线：覆盖观测区间，且每个输入点都离折线足够近。
        let outline = try CalibrationCrossPrediction.outline(
            session: session,
            candidate: best,
            minimumObservedRadiusMm: radii.min()!,
            maximumObservedRadiusMm: radii.max()!
        )
        XCTAssertGreaterThan(outline.count, 10)
        // 逐点偏差（界面用来把明显偏离的点标红）。
        let distances = try CalibrationCrossPrediction.distances(
            session: session,
            candidate: best,
            points: points
        )
        XCTAssertEqual(distances.count, points.count)
        for distance in distances {
            XCTAssertLessThan(distance, 0.01, "干净合成曲线的逐点偏差应接近零")
        }

        for (index, actualPoint) in points.enumerated() where index % 4 == 0 {
            XCTAssertLessThan(
                distanceToPolyline(actualPoint, outline),
                0.02,
                "叠线应覆盖实际描点"
            )
        }
    }

    /// 点到折线的距离（预测叠线是折线，不是孤立的采样点）。
    private func distanceToPolyline(
        _ point: CalibrationPoint,
        _ polyline: [CalibrationPoint]
    ) -> Double {
        guard polyline.count >= 2 else {
            return polyline.first.map { point.distance(to: $0) } ?? .infinity
        }
        var minimum = Double.infinity
        for index in 1..<polyline.count {
            let a = polyline[index - 1]
            let b = polyline[index]
            let dx = b.xMm - a.xMm
            let dy = b.yMm - a.yMm
            let lengthSquared = max(dx * dx + dy * dy, 1e-30)
            let t = min(max(((point.xMm - a.xMm) * dx + (point.yMm - a.yMm) * dy) / lengthSquared, 0), 1)
            let x = a.xMm + t * dx - point.xMm
            let y = a.yMm + t * dy - point.yMm
            minimum = min(minimum, (x * x + y * y).squareRoot())
        }
        return minimum
    }
}
