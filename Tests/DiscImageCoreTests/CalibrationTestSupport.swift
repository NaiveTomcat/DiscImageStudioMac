import Foundation
@testable import DiscImageCore

/// 标定测试共用的合成数据构造器。
enum CalibrationTestSupport {
    static let dvdSectors = 2_295_104

    static func dvdGeometry(
        inner: Double,
        outer: Double,
        sectors: Int = dvdSectors,
        bitLength: Double = 133.3,
        coefficients: (linear: Double, quadratic: Double, cubic: Double) = (0, 0, 0)
    ) -> DiscGeometry {
        DiscGeometry(
            family: .dvd,
            innerRadiusMm: inner,
            outerRadiusMm: outer,
            sectors: sectors,
            channelBitLengthNm: bitLength,
            pitchLinear: coefficients.linear,
            pitchQuadratic: coefficients.quadratic,
            pitchCubic: coefficients.cubic
        )
    }

    static func cdGeometry(inner: Double = 24.5, outer: Double = 56.8, sectors: Int = 359_849) -> DiscGeometry {
        DiscGeometry(
            family: .cd,
            innerRadiusMm: inner,
            outerRadiusMm: outer,
            sectors: sectors,
            linearVelocityMmPerSecond: 1200
        )
    }

    static func bdGeometry(inner: Double = 24, outer: Double = 58) -> DiscGeometry {
        DiscGeometry(
            family: .bluRay,
            innerRadiusMm: inner,
            outerRadiusMm: outer,
            sectors: DiscGeometry.bluRaySingleLayerSectors,
            channelBitLengthNm: DiscGeometry.bluRayChannelBitLengthNm
        )
    }

    static func session(
        generation: DiscGeometry,
        photo: CalibrationPhotoSession? = nil,
        fitOptions: CalibrationFitOptions? = nil
    ) -> CalibrationSession {
        CalibrationSession(
            generation: CalibrationGenerationSnapshot(geometry: generation),
            photo: photo,
            fitOptions: fitOptions
        )
    }

    /// 用轨道模型生成「照片上的盘面点」：同一 progress 下，实际盘的半径与相位。
    ///
    /// 与 `CalibrationCrossModel` 完全一致：观测点角度 = 起始角 + (实际盘累计角 − 生成盘累计角)。
    static func syntheticTrace(
        generation: DiscGeometry,
        actual: DiscGeometry,
        progressRange: ClosedRange<Double> = 0.05...0.95,
        count: Int = 40,
        rotation: Double = 0,
        radialNoiseMm: Double = 0,
        angularNoiseRadians: Double = 0,
        seed: UInt64 = 0x5EED
    ) throws -> [CalibrationPoint] {
        let generated = try CalibrationTrackGeometry(parameters: CalibrationParameters(geometry: generation))
        let actualGeometry = try CalibrationTrackGeometry(parameters: CalibrationParameters(geometry: actual))
        var random = SplitMix64(seed: seed)
        var points: [CalibrationPoint] = []
        for index in 0..<count {
            let fraction = count == 1 ? 0 : Double(index) / Double(count - 1)
            let progress = progressRange.lowerBound
                + (progressRange.upperBound - progressRange.lowerBound) * fraction
            guard let actualPoint = actualGeometry.atProgress(progress),
                  let source = generated.atProgress(progress),
                  let actualAngle = actualGeometry.angleAtRadius(actualPoint.radius) else {
                throw DiscError.invalidGeometry("合成曲线失败：进度 \(progress) 没有有效轨迹。")
            }
            let phase = actualAngle - source.angle
            let radius = actualPoint.radius + radialNoiseMm * random.symmetric()
            let angle = -.pi / 2 + rotation + phase + angularNoiseRadians * random.symmetric()
            points.append(CalibrationPoint(xMm: radius * cos(angle), yMm: radius * sin(angle)))
        }
        return points
    }

    // MARK: - 单应变换

    /// 3×3 行主序：先旋转 + 等比缩放 + 平移，再叠加一个透视项。
    static func homography(
        scale: Double = 12,
        rotationRadians: Double = 0.3,
        translation: (x: Double, y: Double) = (800, 760),
        perspective: Double = 3e-5
    ) -> [Double] {
        let cosine = cos(rotationRadians) * scale
        let sine = sin(rotationRadians) * scale
        return [
            cosine, -sine, translation.x,
            sine, cosine, translation.y,
            perspective, 0, 1,
        ]
    }

    static func apply(_ matrix: [Double], _ point: CalibrationPoint) -> CalibrationPoint {
        let divisor = matrix[6] * point.xMm + matrix[7] * point.yMm + matrix[8]
        let x = (matrix[0] * point.xMm + matrix[1] * point.yMm + matrix[2]) / divisor
        let y = (matrix[3] * point.xMm + matrix[4] * point.yMm + matrix[5]) / divisor
        return CalibrationPoint(xMm: x, yMm: y)
    }

    static func map(
        _ points: [CalibrationPoint],
        through matrix: [Double],
        pixelNoise: Double = 0,
        seed: UInt64 = 0xC0FFEE
    ) -> [CalibrationPoint] {
        var random = SplitMix64(seed: seed)
        return points.map { point in
            let mapped = apply(matrix, point)
            guard pixelNoise > 0 else { return mapped }
            return CalibrationPoint(
                xMm: mapped.xMm + pixelNoise * random.symmetric(),
                yMm: mapped.yMm + pixelNoise * random.symmetric()
            )
        }
    }

    static func circlePoints(radiusMm: Double, count: Int = 24, phase: Double = 0) -> [CalibrationPoint] {
        (0..<count).map { index in
            let angle = phase + 2 * .pi * Double(index) / Double(count)
            return CalibrationPoint(xMm: radiusMm * cos(angle), yMm: radiusMm * sin(angle))
        }
    }

    // MARK: - 伪随机

    /// 确定性伪随机（测试可复现）。
    struct SplitMix64 {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// 均匀分布在 −1…1。
        mutating func symmetric() -> Double {
            Double(next() >> 11) / Double(UInt64(1) << 53) * 2 - 1
        }
    }
}
