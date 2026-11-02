import Foundation

/// 观测曲线在某个半径处的前向预测。
struct CalibrationCrossSample: Sendable, Equatable {
    /// 观测半径（mm）。
    var radius: Double
    /// 该观测半径对应的「原图案」半径（mm）。
    var sourceRadius: Double
    /// 观测角度减去生成角度（环带内连续、不取模）。
    var phase: Double
    /// d(phase)/d(radius)，用于估计相位变化上界。
    var derivative: Double
}

/// 拟合与预测共用的前向相位模型。
///
/// 观测半径 → 生成图案上的半径 → 两套轨道的角度差。观测点允许略超出生成环带
/// （沿正半径连续延拓），这一点与上游一致：生成时设定的内外半径是轨道模型基准，
/// 不是照片观测区域的硬限制。
struct CalibrationCrossModel {
    private let generated: CalibrationTrackGeometry
    private let actual: CalibrationTrackGeometry
    private let family: DiscFamily
    private let identical: Bool

    init(
        generated: CalibrationTrackGeometry,
        actual: CalibrationTrackGeometry,
        family: DiscFamily,
        identical: Bool
    ) {
        self.generated = generated
        self.actual = actual
        self.family = family
        self.identical = identical
    }

    /// 该半径处的预测；无有效正半径延拓时返回 nil（候选作废）。
    func sample(atRadius radius: Double) -> CalibrationCrossSample? {
        guard radius.isFinite, radius > 0, (radius * radius).isFinite else { return nil }
        if identical {
            // 生成的盘被原样刻出时，观测曲线必须是一条精确的直线。
            if !actual.isConstantPitch, actual.progressAtRadius(radius) == nil { return nil }
            return CalibrationCrossSample(radius: radius, sourceRadius: radius, phase: 0, derivative: 0)
        }
        guard let progress = actual.progressAtRadius(radius),
              let source = generated.atProgress(progress) else { return nil }
        let actualGrowth = actual.radialGrowthAtRadius(radius)
        let generatedGrowth = generated.radialGrowthAtRadius(source.radius)
        guard actualGrowth.isFinite, actualGrowth != 0,
              generatedGrowth.isFinite, generatedGrowth != 0 else { return nil }
        let phase = actual.angleAtRadius(radius).map { $0 - source.angle }
        let ratio: Double
        switch family {
        case .cd:
            ratio = radius / source.radius
        case .dvd, .bluRay:
            ratio = (radius * radius + actualGrowth * actualGrowth).squareRoot()
                / (source.radius * source.radius + generatedGrowth * generatedGrowth).squareRoot()
        }
        guard let phase, phase.isFinite else { return nil }
        let derivative = (1 - ratio) / actualGrowth
        guard derivative.isFinite else { return nil }
        return CalibrationCrossSample(
            radius: radius,
            sourceRadius: source.radius,
            phase: phase,
            derivative: derivative
        )
    }

    /// 区间内 |d(phase)/d(radius)| 的上界（不把相位折回整圈）。
    func derivativeBound(first: CalibrationCrossSample, last: CalibrationCrossSample) -> Double {
        if identical { return 0 }
        if family == .cd {
            return max(abs(first.derivative), abs(last.derivative))
        }
        let actualBounds = actual.radialGrowthBounds(
            firstRadius: first.radius,
            lastRadius: last.radius
        )
        let generatedBounds = generated.radialGrowthBounds(
            firstRadius: first.sourceRadius,
            lastRadius: last.sourceRadius
        )
        let minimumGrowth = max(actualBounds.minimum, 1e-15)
        let minimumRatio = (first.radius * first.radius
            + actualBounds.minimum * actualBounds.minimum).squareRoot()
            / (last.sourceRadius * last.sourceRadius
                + generatedBounds.maximum * generatedBounds.maximum).squareRoot()
        let maximumRatio = (last.radius * last.radius
            + actualBounds.maximum * actualBounds.maximum).squareRoot()
            / (first.sourceRadius * first.sourceRadius
                + generatedBounds.minimum * generatedBounds.minimum).squareRoot()
        let bound = max(abs(1 - minimumRatio), abs(1 - maximumRatio)) / minimumGrowth
        return bound.isFinite ? bound : .infinity
    }
}
