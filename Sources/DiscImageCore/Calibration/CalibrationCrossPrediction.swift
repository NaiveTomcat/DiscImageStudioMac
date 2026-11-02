import Foundation

/// 候选参数下的完整预测曲线（界面上叠加到照片上让用户对照）。
///
/// 预测必须在**观测半径区间**上连续计算，保留参数所预测的弯曲，
/// 而不是理想直线或任意穿点的样条；也不要折回模 2π（那会隐藏多绕的圈）。
public enum CalibrationCrossPrediction {
    /// 预测曲线在给定观测半径处的点（盘面毫米坐标）。
    public static func point(
        session: CalibrationSession,
        candidate: CalibrationFitCandidate,
        radiusMm: Double,
        armIndex: Int = 0
    ) throws -> CalibrationPoint {
        let model = try makeModel(session: session, candidate: candidate)
        let startAngle = Self.startAngle(armIndex: armIndex, rotation: candidate.rotationRadians)
        guard let sample = model.sample(atRadius: radiusMm) else {
            throw DiscError.invalidGeometry("该观测半径在当前参数下没有有效的正半径曲线延拓。")
        }
        return CalibrationPoint(
            xMm: sample.radius * cos(startAngle + sample.phase),
            yMm: sample.radius * sin(startAngle + sample.phase)
        )
    }

    /// 在观测半径区间上采样整条预测曲线。
    ///
    /// 采样规则与上游一致：半径步长不超过 0.2 mm，弦高误差不超过 0.01 mm，
    /// 且相邻采样点的相位变化不超过 5°，因此端点重合也藏不住中间的绕圈。
    public static func outline(
        session: CalibrationSession,
        candidate: CalibrationFitCandidate,
        minimumObservedRadiusMm: Double,
        maximumObservedRadiusMm: Double,
        armIndex: Int = 0,
        maxPoints: Int = 20000
    ) throws -> [CalibrationPoint] {
        guard minimumObservedRadiusMm.isFinite, maximumObservedRadiusMm.isFinite,
              minimumObservedRadiusMm > 0,
              maximumObservedRadiusMm > minimumObservedRadiusMm else {
            throw DiscError.invalidGeometry("预测曲线需要有限、递增且大于零的观测半径区间。")
        }
        guard maxPoints >= 2, maxPoints <= 1_000_000 else {
            throw DiscError.invalidGeometry("预测曲线点数上限无效。")
        }
        let model = try makeModel(session: session, candidate: candidate)
        let startAngle = Self.startAngle(armIndex: armIndex, rotation: candidate.rotationRadians)

        func sample(_ radius: Double) throws -> CalibrationCrossSample {
            guard let value = model.sample(atRadius: radius) else {
                throw DiscError.invalidGeometry("该观测半径在当前参数下没有有效的正半径曲线延拓，请检查照片尺度、盘心或参数范围。")
            }
            return value
        }
        func point(_ value: CalibrationCrossSample) -> CalibrationPoint {
            CalibrationPoint(
                xMm: value.radius * cos(startAngle + value.phase),
                yMm: value.radius * sin(startAngle + value.phase)
            )
        }
        func chordDistance(_ point: CalibrationPoint, _ a: CalibrationPoint, _ b: CalibrationPoint) -> Double {
            let dx = b.xMm - a.xMm
            let dy = b.yMm - a.yMm
            let lengthSquared = max(1e-30, dx * dx + dy * dy)
            let t = min(max(((point.xMm - a.xMm) * dx + (point.yMm - a.yMm) * dy) / lengthSquared, 0), 1)
            let px = point.xMm - a.xMm - t * dx
            let py = point.yMm - a.yMm - t * dy
            return (px * px + py * py).squareRoot()
        }

        let first = try sample(minimumObservedRadiusMm)
        let last = try sample(maximumObservedRadiusMm)
        var points: [CalibrationPoint] = []

        func segment(_ a: CalibrationCrossSample, _ b: CalibrationCrossSample, depth: Int) throws {
            let span = b.radius - a.radius
            let middle = try sample(a.radius + span / 2)
            let pa = point(a)
            let pb = point(b)
            var split = span > 0.2 || model.derivativeBound(first: a, last: b) * span > .pi / 36
            if !split {
                let quarterOne = try sample(a.radius + span / 4)
                let quarterThree = try sample(a.radius + span * 0.75)
                split = chordDistance(point(middle), pa, pb) > 0.01
                    || chordDistance(point(quarterOne), pa, pb) > 0.01
                    || chordDistance(point(quarterThree), pa, pb) > 0.01
            }
            if split {
                guard depth < 48, points.count < maxPoints - 1 else {
                    throw DiscError.invalidGeometry("完整曲线采样超出点数上限；请缩小预测范围或提高采样上限后再确认形状。")
                }
                try segment(a, middle, depth: depth + 1)
                try segment(middle, b, depth: depth + 1)
            } else {
                guard points.count < maxPoints - 1 else {
                    throw DiscError.invalidGeometry("完整曲线采样超出点数上限；请缩小预测范围或提高采样上限后再确认形状。")
                }
                points.append(pa)
            }
        }

        try segment(first, last, depth: 0)
        points.append(point(last))
        return points
    }

    /// 在指定半径列表上逐点预测（导出/导出前检查用）。
    public static func curve(
        session: CalibrationSession,
        candidate: CalibrationFitCandidate,
        radiiMm: [Double],
        armIndex: Int = 0
    ) throws -> [CalibrationPoint] {
        try radiiMm.map {
            try point(session: session, candidate: candidate, radiusMm: $0, armIndex: armIndex)
        }
    }

    // MARK: - 内部

    static func startAngle(armIndex: Int, rotation: Double) -> Double {
        -.pi / 2 + Double(armIndex) * .pi / 2 + rotation
    }

    private static func makeModel(
        session: CalibrationSession,
        candidate: CalibrationFitCandidate
    ) throws -> CalibrationCrossModel {
        try session.validate()
        let generatedParameters = CalibrationParameters(
            geometry: session.generation.geometry,
            drawingStartSector: session.generation.drawingStartSector,
            drawingEndSectorExclusive: session.generation.drawingEndSectorExclusive
        )
        var actualParameters = generatedParameters.replacingRadii(
            inner: candidate.innerRadiusMm,
            outer: candidate.outerRadiusMm
        )
        if generatedParameters.family == .dvd {
            actualParameters = actualParameters.replacingPitch(
                linear: candidate.pitchLinear,
                quadratic: candidate.pitchQuadratic,
                cubic: candidate.pitchCubic
            )
        }
        try actualParameters.validate()
        let generated = try CalibrationTrackGeometry(parameters: generatedParameters)
        let actual = try CalibrationTrackGeometry(parameters: actualParameters)
        return CalibrationCrossModel(
            generated: generated,
            actual: actual,
            family: generatedParameters.family,
            identical: actualParameters == generatedParameters
        )
    }
}

extension CalibrationCrossPrediction {
    /// 每个输入点相对预测曲线的垂直距离（mm），用于界面上把明显偏离的点标红。
    ///
    /// 在输入点半径附近取一小段预测折线（±0.05 mm）再算点到线段距离，
    /// 这样得到的数值与「局部法向偏差」同量级，而不是把切向绕圈误差放大成原始角差。
    public static func distances(
        session: CalibrationSession,
        candidate: CalibrationFitCandidate,
        points: [CalibrationPoint]
    ) throws -> [Double] {
        guard !points.isEmpty else { return [] }
        let model = try makeModel(session: session, candidate: candidate)
        let startAngle = startAngle(armIndex: 0, rotation: candidate.rotationRadians)

        func predicted(_ radius: Double) -> CalibrationPoint? {
            guard let sample = model.sample(atRadius: radius) else { return nil }
            return CalibrationPoint(
                xMm: sample.radius * cos(startAngle + sample.phase),
                yMm: sample.radius * sin(startAngle + sample.phase)
            )
        }

        return points.map { point in
            let radius = point.radiusMm
            let span = max(0.05, radius * 0.002)
            var polyline: [CalibrationPoint] = []
            for offset in [-span, 0, span] {
                let sampleRadius = radius + offset
                guard sampleRadius > 0, let value = predicted(sampleRadius) else { continue }
                polyline.append(value)
            }
            guard polyline.count >= 2 else { return .infinity }
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
}
