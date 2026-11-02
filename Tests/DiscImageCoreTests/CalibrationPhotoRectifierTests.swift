import XCTest
@testable import DiscImageCore

/// 照片矫正：两条实体轮廓联合拟合单应变换。
final class CalibrationPhotoRectifierTests: XCTestCase {
    func testRecoversKnownHomographyFromNoisyCircles() throws {
        let matrix = CalibrationTestSupport.homography()
        let outer = CalibrationTestSupport.map(
            CalibrationTestSupport.circlePoints(radiusMm: 60, count: 24),
            through: matrix,
            pixelNoise: 0.3
        )
        let hole = CalibrationTestSupport.map(
            CalibrationTestSupport.circlePoints(radiusMm: 7.5, count: 16),
            through: matrix,
            pixelNoise: 0.3
        )
        let result = try CalibrationPhotoRectifier.fitDetailed(
            outerEdge: outer,
            centerHole: hole,
            discSize: .standard12cm
        )
        XCTAssertTrue(result.transform.isValidForDisc(60))
        XCTAssertLessThan(result.outerRmsPixels, 1)
        XCTAssertLessThan(result.holeRmsPixels, 1)
        XCTAssertEqual(result.rmsPixels, max(result.outerRmsPixels, result.holeRmsPixels), accuracy: 1e-12)
        XCTAssertEqual(result.transform.matrix9.count, 9)
        // 简化入口返回同样的变换与合并残差。
        let simple = try CalibrationPhotoRectifier.fit(
            outerEdge: outer,
            centerHole: hole,
            discSize: .standard12cm
        )
        XCTAssertEqual(simple.rmsPixels, result.rmsPixels, accuracy: 1e-12)
        XCTAssertEqual(simple.transform, result.transform)

        // 盘面坐标只被整体旋转：半径不变，角度差为常数。
        let samples = [
            CalibrationPoint(xMm: 30, yMm: 0),
            CalibrationPoint(xMm: 0, yMm: 45),
            CalibrationPoint(xMm: -52, yMm: 8),
            CalibrationPoint(xMm: 20, yMm: -25),
        ]
        var angleOffset: Double?
        for sample in samples {
            let pixel = CalibrationTestSupport.apply(matrix, sample)
            let recovered = result.transform.sourceToDisc(pixel)
            XCTAssertEqual(recovered.radiusMm, sample.radiusMm, accuracy: 0.05)
            let offset = normalized(recovered.angleRadians - sample.angleRadians)
            if let angleOffset {
                XCTAssertEqual(offset, angleOffset, accuracy: 0.002)
            } else {
                angleOffset = offset
            }
            // 反变换自洽。
            let roundTrip = result.transform.discToSource(recovered)
            XCTAssertEqual(roundTrip.xMm, pixel.xMm, accuracy: 1e-6)
            XCTAssertEqual(roundTrip.yMm, pixel.yMm, accuracy: 1e-6)
        }
    }

    func testMiniDiscUsesFortyMillimetreOuterRadius() throws {
        let scale = 15.0
        let matrix = CalibrationTestSupport.homography(scale: scale, rotationRadians: 0, translation: (x: 500, y: 500))
        let outer = CalibrationTestSupport.map(
            CalibrationTestSupport.circlePoints(radiusMm: 40, count: 20),
            through: matrix
        )
        let hole = CalibrationTestSupport.map(
            CalibrationTestSupport.circlePoints(radiusMm: 7.5, count: 12),
            through: matrix
        )
        let result = try CalibrationPhotoRectifier.fit(
            outerEdge: outer,
            centerHole: hole,
            discSize: .mini8cm
        )
        // 外缘上的点应恢复到 40 mm。
        let recovered = result.transform.sourceToDisc(CalibrationTestSupport.apply(matrix, CalibrationPoint(xMm: 40, yMm: 0)))
        XCTAssertEqual(recovered.radiusMm, 40, accuracy: 0.02)
        XCTAssertLessThan(result.rmsPixels, 0.5)
    }

    func testTooFewPointsIsRejected() {
        let outer = CalibrationTestSupport.circlePoints(radiusMm: 60, count: 4)
        let hole = CalibrationTestSupport.circlePoints(radiusMm: 7.5, count: 12)
        XCTAssertThrowsError(
            try CalibrationPhotoRectifier.fit(outerEdge: outer, centerHole: hole, discSize: .standard12cm)
        ) { error in
            XCTAssertTrue(String(describing: error).contains("至少 5 个"))
        }
    }

    func testCollinearBoundaryIsRejected() {
        let matrix = CalibrationTestSupport.homography()
        let line = (0..<12).map {
            CalibrationPoint(xMm: 100 + Double($0) * 30, yMm: 400)
        }
        let hole = CalibrationTestSupport.map(
            CalibrationTestSupport.circlePoints(radiusMm: 7.5, count: 12),
            through: matrix
        )
        XCTAssertThrowsError(
            try CalibrationPhotoRectifier.fit(outerEdge: line, centerHole: hole, discSize: .standard12cm)
        )
    }

    /// 把「印刷圆环」当成中心孔：两条圆的半径比不符，联合拟合必须失败。
    func testWrongHoleRadiusIsRejected() {
        let matrix = CalibrationTestSupport.homography()
        let outer = CalibrationTestSupport.map(
            CalibrationTestSupport.circlePoints(radiusMm: 60, count: 24),
            through: matrix
        )
        let printedRing = CalibrationTestSupport.map(
            CalibrationTestSupport.circlePoints(radiusMm: 11, count: 16),
            through: matrix
        )
        XCTAssertThrowsError(
            try CalibrationPhotoRectifier.fit(
                outerEdge: outer,
                centerHole: printedRing,
                discSize: .standard12cm
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("无法同时吻合")
                    || String(describing: error).contains("内缘")
            )
        }
    }

    func testDegenerateTransformIsRejected() {
        // 全零矩阵不可逆。
        XCTAssertThrowsError(try CalibrationPhotoTransform(discToSourceMatrix9: [Double](repeating: 0, count: 9)))
        XCTAssertThrowsError(try CalibrationPhotoTransform(discToSourceMatrix9: [1, 0]))
    }

    private func normalized(_ angle: Double) -> Double {
        atan2(sin(angle), cos(angle))
    }
}
