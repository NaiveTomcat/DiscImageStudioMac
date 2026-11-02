import Foundation

/// 标定用的轨道参数（比 `DiscGeometry` 多带 BD 的绘图扇区范围）。
///
/// 与 `DiscGeometry` 保持一一对应：`geometry` 负责编解码，`CalibrationParameters`
/// 负责标定需要的「绘图起止 + 轨道模型」。两者不重复实现几何公式，
/// `trackLengthMm` 直接沿用 HANDOFF §2.2 的三条公式。
struct CalibrationParameters: Equatable, Sendable {
    var family: DiscFamily
    var innerRadiusMm: Double
    var outerRadiusMm: Double
    var sectors: Int
    /// CD 是线速度（mm/s），DVD/BD 是位长（nm）。
    var linearDensity: Double
    var pitchLinear: Double
    var pitchQuadratic: Double
    var pitchCubic: Double
    var invertMapping: Bool
    var drawingStartSector: Int
    var drawingEndSectorExclusive: Int

    init(
        geometry: DiscGeometry,
        drawingStartSector: Int = 0,
        drawingEndSectorExclusive: Int = 0
    ) {
        family = geometry.family
        innerRadiusMm = geometry.innerRadiusMm
        outerRadiusMm = geometry.outerRadiusMm
        sectors = geometry.sectors
        switch geometry.family {
        case .cd:
            linearDensity = geometry.linearVelocityMmPerSecond
        case .dvd, .bluRay:
            linearDensity = geometry.channelBitLengthNm
        }
        pitchLinear = geometry.pitchLinear
        pitchQuadratic = geometry.pitchQuadratic
        pitchCubic = geometry.pitchCubic
        invertMapping = geometry.invertMapping
        self.drawingStartSector = drawingStartSector
        self.drawingEndSectorExclusive = drawingEndSectorExclusive
    }

    init(
        family: DiscFamily,
        innerRadiusMm: Double,
        outerRadiusMm: Double,
        sectors: Int,
        linearDensity: Double,
        pitchLinear: Double = 0,
        pitchQuadratic: Double = 0,
        pitchCubic: Double = 0,
        invertMapping: Bool = false,
        drawingStartSector: Int = 0,
        drawingEndSectorExclusive: Int = 0
    ) {
        self.family = family
        self.innerRadiusMm = innerRadiusMm
        self.outerRadiusMm = outerRadiusMm
        self.sectors = sectors
        self.linearDensity = linearDensity
        self.pitchLinear = pitchLinear
        self.pitchQuadratic = pitchQuadratic
        self.pitchCubic = pitchCubic
        self.invertMapping = invertMapping
        self.drawingStartSector = drawingStartSector
        self.drawingEndSectorExclusive = drawingEndSectorExclusive
    }

    /// 总轨道长（mm），三条公式见 HANDOFF §2.2。
    var trackLengthMm: Double {
        switch family {
        case .cd:
            return Double(sectors) / 75.0 * linearDensity
        case .dvd:
            return Double(sectors) * Double(DiscGeometry.dvdChannelBitsPerSector) * linearDensity * 1e-6
        case .bluRay:
            return Double(sectors) / Double(DiscGeometry.bluRaySectorsPerCluster)
                * Double(DiscGeometry.bluRayChannelBitsPerCluster) * linearDensity * 1e-6
        }
    }

    var hasCubicPitch: Bool {
        pitchLinear != 0 || pitchQuadratic != 0 || pitchCubic != 0
    }

    /// 转回共享几何（写回工程设置用）。
    var geometry: DiscGeometry {
        DiscGeometry(
            family: family,
            innerRadiusMm: innerRadiusMm,
            outerRadiusMm: outerRadiusMm,
            sectors: sectors,
            linearVelocityMmPerSecond: family == .cd ? linearDensity : 1200,
            channelBitLengthNm: family == .cd ? 133.3 : linearDensity,
            pitchLinear: pitchLinear,
            pitchQuadratic: pitchQuadratic,
            pitchCubic: pitchCubic,
            invertMapping: invertMapping
        )
    }

    /// 内半径以内的环带被裁掉；BD 还要按绘图扇区范围裁。
    var drawingInnerRadiusMm: Double {
        drawingRadius(sector: drawingStartSector, fallback: innerRadiusMm)
    }

    var drawingOuterRadiusMm: Double {
        drawingRadius(sector: drawingEndSectorExclusive, fallback: outerRadiusMm)
    }

    private func drawingRadius(sector: Int, fallback: Double) -> Double {
        guard sector != 0, sectors > 0,
              let track = try? CalibrationTrackGeometry(parameters: self),
              let point = track.atProgress(Double(sector) / Double(sectors)) else {
            return fallback
        }
        return point.radius
    }

    func replacingRadii(inner: Double, outer: Double) -> CalibrationParameters {
        var copy = self
        copy.innerRadiusMm = inner
        copy.outerRadiusMm = outer
        return copy
    }

    func replacingPitch(linear: Double, quadratic: Double, cubic: Double) -> CalibrationParameters {
        var copy = self
        copy.pitchLinear = linear
        copy.pitchQuadratic = quadratic
        copy.pitchCubic = cubic
        return copy
    }

    func validate() throws {
        guard sectors > 0 else {
            throw DiscError.invalidGeometry("扇区数必须为正数。")
        }
        guard innerRadiusMm.isFinite, innerRadiusMm > 0,
              outerRadiusMm.isFinite, outerRadiusMm > innerRadiusMm else {
            throw DiscError.invalidGeometry("内外半径无效（\(innerRadiusMm) → \(outerRadiusMm) mm）。")
        }
        guard linearDensity.isFinite, linearDensity > 0 else {
            throw DiscError.invalidGeometry("线速度／位长必须为正数。")
        }
        let length = trackLengthMm
        guard length.isFinite, length > outerRadiusMm - innerRadiusMm else {
            throw DiscError.invalidGeometry("总轨道长无效，请检查扇区数与线速度／位长。")
        }
        try geometry.validate()
        if family != .dvd, hasCubicPitch {
            throw DiscError.unsupported("三次轨距参数仅适用于 DVD。")
        }
        if drawingStartSector < 0 || drawingEndSectorExclusive < 0
            || drawingStartSector >= sectors || drawingEndSectorExclusive > sectors
            || (drawingEndSectorExclusive != 0 && drawingEndSectorExclusive <= drawingStartSector) {
            throw DiscError.invalidGeometry("标定图案的可绘制扇区范围无效。")
        }
        if family != .bluRay, drawingStartSector != 0 || drawingEndSectorExclusive != 0 {
            throw DiscError.invalidGeometry("只有蓝光使用绘图扇区范围。")
        }
        if family == .bluRay,
           drawingStartSector % DiscGeometry.bluRaySectorsPerCluster != 0
            || drawingEndSectorExclusive % DiscGeometry.bluRaySectorsPerCluster != 0 {
            throw DiscError.invalidGeometry("蓝光标定需要完整的 32 扇区簇。")
        }
    }
}

/// 标定轨道模型：连续相位 `θ(r)` 与弧长 `s(r)`。
///
/// 与上游 `CalibrationGeometry` 的三个分支一致：
/// - CD：面积线性的阿基米德近似（`progress = (r²−ri²)/(ro²−ri²)`）；
/// - DVD（无三次系数）/BD：精确阿基米德弧长，`b` 由总轨长反解；
/// - DVD（有三次系数）：`dr/dθ = b·(1 + c1x + c2x² + c3x³)`，`x=(r−ri)/(ro−ri)`，
///   弧长与角度用 Gauss-Legendre 积分表求，`b` 由总轨长反解。
struct CalibrationTrackGeometry {
    enum Mode: Sendable, Equatable {
        case areaLinear
        case archimedean
        case cubic
    }

    let parameters: CalibrationParameters
    let mode: Mode
    /// 每弧度径向增量 `b`（mm/rad）。
    let growth: Double
    let isConstantPitch: Bool

    private let table: TrackTable?
    private let inner2: Double
    private let squaredRange: Double

    init(parameters: CalibrationParameters, radiusMarginMm: Double = 1.0) throws {
        try parameters.validate()
        self.parameters = parameters
        inner2 = parameters.innerRadiusMm * parameters.innerRadiusMm
        squaredRange = parameters.outerRadiusMm * parameters.outerRadiusMm - inner2
        isConstantPitch = !parameters.hasCubicPitch

        if parameters.family == .cd {
            mode = .areaLinear
            growth = squaredRange / (2 * parameters.trackLengthMm)
            table = nil
            return
        }

        if !parameters.hasCubicPitch {
            mode = .archimedean
            guard let solved = Self.solveArchimedeanGrowth(
                inner: parameters.innerRadiusMm,
                outer: parameters.outerRadiusMm,
                trackLengthMm: parameters.trackLengthMm
            ) else {
                throw DiscError.invalidGeometry("无法由总轨长反解螺距，请检查内外半径与扇区数。")
            }
            growth = solved
            table = nil
            return
        }

        // DVD 三次轨距：先解 b，再建积分表。
        // 弧长采用薄轨近似 s(r) ≈ ∫ r/(b·Q) dr（DVD 上相对误差 (b/r)²/8 ≈ 5e-13，
        // 远小于任何可测精度），因此 b = ∫ r/Q dr / L 有闭式解，无需迭代。
        guard let solved = Self.solveThinCubicGrowth(parameters: parameters) else {
            throw DiscError.invalidGeometry("三次轨距在给定半径范围内无法解析，请检查系数。")
        }
        growth = solved
        let low = max(0.05, parameters.innerRadiusMm - radiusMarginMm)
        let high = parameters.outerRadiusMm + radiusMarginMm
        guard let built = TrackTable(
            parameters: parameters,
            growth: solved,
            lowRadiusMm: low,
            highRadiusMm: high
        ) else {
            throw DiscError.invalidGeometry("三次轨距积分表构建失败。")
        }
        mode = .cubic
        table = built
    }

    // MARK: - 查询

    /// 以半径求累计进度（可为负或大于 1：观测点允许略超出生成环带）。
    /// 有效值返回 `progress`（以总轨长归一），无有效正半径延拓时返回 nil。
    func progressAtRadius(_ radius: Double) -> Double? {
        guard radius.isFinite, radius > 0, (radius * radius).isFinite else { return nil }
        switch mode {
        case .areaLinear:
            return (radius * radius - inner2) / squaredRange
        case .archimedean:
            let arc = Self.archimedeanArc(
                from: parameters.innerRadiusMm,
                to: radius,
                growth: growth
            )
            let progress = arc / parameters.trackLengthMm
            return progress.isFinite ? progress : nil
        case .cubic:
            guard let table, let arc = table.arc(at: radius) else { return nil }
            let progress = arc.value / parameters.trackLengthMm
            return progress.isFinite ? progress : nil
        }
    }

    /// 以进度求（半径，角度）。进度可略超出 0…1（连续延拓）。
    func atProgress(_ progress: Double) -> (radius: Double, angle: Double)? {
        guard progress.isFinite else { return nil }
        switch mode {
        case .areaLinear:
            let squared = inner2 + progress * squaredRange
            guard squared.isFinite, squared > 0 else { return nil }
            let radius = squared.squareRoot()
            let angle = (radius - parameters.innerRadiusMm) / growth
            return angle.isFinite ? (radius, angle) : nil
        case .archimedean:
            let target = progress * parameters.trackLengthMm
            guard target.isFinite,
                  let radius = Self.archimedeanRadius(
                      forArc: target,
                      inner: parameters.innerRadiusMm,
                      outer: parameters.outerRadiusMm,
                      growth: growth
                  ) else { return nil }
            let angle = (radius - parameters.innerRadiusMm) / growth
            return angle.isFinite ? (radius, angle) : nil
        case .cubic:
            guard let table, let radius = table.radius(forArc: progress * parameters.trackLengthMm),
                  let angle = table.angle(at: radius) else { return nil }
            return angle.value.isFinite ? (radius, angle.value) : nil
        }
    }

    /// 半径处的累计角度（弧度，0 在内半径）。
    func angleAtRadius(_ radius: Double) -> Double? {
        guard radius.isFinite, radius > 0 else { return nil }
        switch mode {
        case .areaLinear, .archimedean:
            let angle = (radius - parameters.innerRadiusMm) / growth
            return angle.isFinite ? angle : nil
        case .cubic:
            guard let table, let angle = table.angle(at: radius) else { return nil }
            return angle.value.isFinite ? angle.value : nil
        }
    }

    /// 半径处的局部径向增量 `dr/dθ`（mm/rad）。
    func radialGrowthAtRadius(_ radius: Double) -> Double {
        guard mode == .cubic else { return growth }
        let width = parameters.outerRadiusMm - parameters.innerRadiusMm
        guard width > 0 else { return growth }
        return growth * pitchShape((radius - parameters.innerRadiusMm) / width)
    }

    /// 区间内 `dr/dθ` 的上下界（用于预测曲线采样与相位变化界）。
    func radialGrowthBounds(
        firstRadius: Double,
        lastRadius: Double
    ) -> (minimum: Double, maximum: Double) {
        guard mode == .cubic else { return (growth, growth) }
        let width = parameters.outerRadiusMm - parameters.innerRadiusMm
        guard width > 0 else { return (growth, growth) }
        let low = (firstRadius - parameters.innerRadiusMm) / width
        let high = (lastRadius - parameters.innerRadiusMm) / width
        let a = parameters.pitchLinear
        let b = parameters.pitchQuadratic
        let c = parameters.pitchCubic
        func shape(_ x: Double) -> Double { 1 + x * (a + x * (b + x * c)) }
        var minimum = min(shape(low), shape(high))
        var maximum = max(shape(low), shape(high))
        func include(_ x: Double) {
            guard x.isFinite, x > low, x < high else { return }
            let value = shape(x)
            minimum = min(minimum, value)
            maximum = max(maximum, value)
        }
        if c == 0 {
            if b != 0 { include(-a / (2 * b)) }
        } else {
            let discriminant = b * b - 3 * c * a
            if discriminant >= 0 {
                let root = discriminant.squareRoot()
                include((-b - root) / (3 * c))
                include((-b + root) / (3 * c))
            }
        }
        return (minimum * growth, maximum * growth)
    }

    /// 三次轨距形状 `Q(x)`。
    private func pitchShape(_ x: Double) -> Double {
        1 + x * (parameters.pitchLinear + x * (parameters.pitchQuadratic + x * parameters.pitchCubic))
    }

    // MARK: - 弧长求解

    /// 精确阿基米德弧长原函数：`∫ sqrt(r²+b²)/b dr`。
    static func archimedeanPrimitive(radius: Double, growth b: Double) -> Double {
        // 0.5·(r·sqrt(r²+b²) + b²·asinh(r/b)) / b
        (radius * (radius * radius + b * b).squareRoot() + b * b * asinh(radius / b)) / (2 * b)
    }

    static func archimedeanArc(from first: Double, to second: Double, growth b: Double) -> Double {
        archimedeanPrimitive(radius: second, growth: b)
            - archimedeanPrimitive(radius: first, growth: b)
    }

    static func solveArchimedeanGrowth(
        inner: Double,
        outer: Double,
        trackLengthMm: Double
    ) -> Double? {
        // 弧长随 b 增大而**减小**（b→∞ 时退化成长度 ro−ri 的径向直线）。
        func arc(_ b: Double) -> Double { archimedeanArc(from: inner, to: outer, growth: b) }
        var low = 1e-15
        var high = max(outer, 1.0)
        guard arc(low) > trackLengthMm else { return nil }
        var iterations = 0
        while arc(high) > trackLengthMm {
            high *= 2
            iterations += 1
            if iterations > 200 || !high.isFinite { return nil }
        }
        for _ in 0..<200 {
            let middle = (low + high) / 2
            if arc(middle) > trackLengthMm { low = middle } else { high = middle }
        }
        let solved = (low + high) / 2
        return solved.isFinite && solved > 0 ? solved : nil
    }

    static func archimedeanRadius(
        forArc target: Double,
        inner: Double,
        outer: Double,
        growth b: Double
    ) -> Double? {
        guard target.isFinite else { return nil }
        let innerPrimitive = archimedeanPrimitive(radius: inner, growth: b)
        let targetPrimitive = innerPrimitive + target
        guard targetPrimitive > 0 else { return nil }

        func error(_ radius: Double) -> Double {
            archimedeanPrimitive(radius: radius, growth: b) - targetPrimitive
        }
        // 薄轨近似给初值（对 DVD 的相对误差 ~1e-11），随后 Newton 收敛到机器精度。
        let squared = inner * inner + 2 * b * target
        var radius = squared > 0 ? squared.squareRoot() : (b * 0.5)
        var converged = false
        for _ in 0..<30 {
            let current = error(radius)
            let derivative = (radius * radius + b * b).squareRoot() / b
            guard derivative.isFinite, derivative > 0 else { break }
            let next = radius - current / derivative
            guard next.isFinite, next > 0 else { break }
            let stepSize = abs(next - radius)
            radius = next
            if stepSize <= 1e-15 * max(1, radius) { converged = true; break }
        }
        if !converged || abs(error(radius)) > max(1e-12, abs(targetPrimitive) * 1e-15) {
            // 极端参数下的稳健回退：弧长对半径单调，二分一定收敛。
            var low = 1e-12
            var high = max(inner, outer) * 2
            var iterations = 0
            while error(high) < 0 {
                high *= 2
                iterations += 1
                if iterations > 200 || !high.isFinite { return nil }
            }
            for _ in 0..<200 {
                let middle = (low + high) / 2
                if error(middle) < 0 { low = middle } else { high = middle }
            }
            radius = (low + high) / 2
        }
        guard radius.isFinite, radius > 0 else { return nil }
        return radius
    }

    /// 解三次轨距的径向增量 `b`：薄轨近似下 `b = ∫ r/Q dr / L`。
    static func solveThinCubicGrowth(parameters: CalibrationParameters) -> Double? {
        let inner = parameters.innerRadiusMm
        let outer = parameters.outerRadiusMm
        let length = parameters.trackLengthMm
        let a = parameters.pitchLinear
        let b = parameters.pitchQuadratic
        let c = parameters.pitchCubic
        func shape(_ radius: Double) -> Double {
            let x = (radius - inner) / (outer - inner)
            return 1 + x * (a + x * (b + x * c))
        }
        let integral = gaussIntegral(from: inner, to: outer, intervals: 16) { radius in
            radius / shape(radius)
        }
        guard integral.isFinite, integral > 0 else { return nil }
        let growth = integral / length
        return growth.isFinite && growth > 0 ? growth : nil
    }

    // MARK: - Gauss-Legendre 8 点积分

    private static let gaussNodes: [Double] = [
        0.1834346424956498, 0.5255324099163290,
        0.7966664774136267, 0.9602898564975363,
    ]
    private static let gaussWeights: [Double] = [
        0.3626837833783620, 0.3137066458778873,
        0.2223810344533745, 0.1012285362903763,
    ]

    /// 复合 8 点 Gauss-Legendre 积分（区间等分 `intervals` 段）。
    static func gaussIntegral(
        from first: Double,
        to second: Double,
        intervals: Int,
        _ integrand: (Double) -> Double
    ) -> Double {
        guard intervals > 0 else { return 0 }
        let step = (second - first) / Double(intervals)
        guard step.isFinite, step != 0 else { return 0 }
        var total = 0.0
        for interval in 0..<intervals {
            let a = first + Double(interval) * step
            let middle = a + step / 2
            let half = step / 2
            var sum = 0.0
            for index in 0..<gaussNodes.count {
                let offset = half * gaussNodes[index]
                sum += gaussWeights[index] * (integrand(middle + offset) + integrand(middle - offset))
            }
            total += sum * half
        }
        return total
    }
}

/// 三次轨距的弧长 / 角度积分表（按半径等距布点，三次 Hermite 插值）。
///
/// 用薄轨近似：弧长对半径的微分为 `r/(b·Q)`，角度对半径的微分为 `1/(b·Q)`。
/// 两项都被积成光滑函数，因此在 96 段 × 8 点 Gauss 之后，Hermite 插值的角度误差
/// 约 1.5e-8 rad（≈ 1e-6 mm），弧长误差约 1.4e-6 mm。
struct TrackTable {
    private static let intervalCount = 96
    private static let quadratureNodes: [Double] = [
        0.1834346424956498, 0.5255324099163290,
        0.7966664774136267, 0.9602898564975363,
    ]
    private static let quadratureWeights: [Double] = [
        0.3626837833783620, 0.3137066458778873,
        0.2223810344533745, 0.1012285362903763,
    ]

    let lowRadiusMm: Double
    let highRadiusMm: Double
    private let step: Double
    private let radii: [Double]
    private let arcValues: [Double]
    private let arcSlopes: [Double]
    private let angleValues: [Double]
    private let angleSlopes: [Double]

    init?(
        parameters: CalibrationParameters,
        growth: Double,
        lowRadiusMm: Double,
        highRadiusMm: Double
    ) {
        let inner = parameters.innerRadiusMm
        let outer = parameters.outerRadiusMm
        let width = outer - inner
        guard lowRadiusMm > 0, highRadiusMm > lowRadiusMm, width > 0, growth > 0 else { return nil }
        let count = Self.intervalCount
        let step = (highRadiusMm - lowRadiusMm) / Double(count)
        guard step > 0, step.isFinite else { return nil }
        let a = parameters.pitchLinear
        let b = parameters.pitchQuadratic
        let c = parameters.pitchCubic

        // 局部形状：arc' = r/(bQ)，angle' = 1/(bQ)。
        func integrands(_ radius: Double) -> (arc: Double, angle: Double) {
            let x = (radius - inner) / width
            let shape = 1 + x * (a + x * (b + x * c))
            let g = growth * shape
            return (radius / g, 1 / g)
        }
        func integrate(_ first: Double, _ last: Double) -> (arc: Double, angle: Double)? {
            let middle = (first + last) / 2
            let half = (last - first) / 2
            var arc = 0.0
            var angle = 0.0
            for index in 0..<Self.quadratureNodes.count {
                let offset = half * Self.quadratureNodes[index]
                let weight = Self.quadratureWeights[index] * half
                let forward = integrands(middle + offset)
                let backward = integrands(middle - offset)
                arc += weight * (forward.arc + backward.arc)
                angle += weight * (forward.angle + backward.angle)
            }
            return (arc.isFinite && angle.isFinite) ? (arc, angle) : nil
        }

        self.lowRadiusMm = lowRadiusMm
        self.highRadiusMm = highRadiusMm
        self.step = step
        var radiiValues = [Double](repeating: 0, count: count + 1)
        var arc = [Double](repeating: 0, count: count + 1)
        var arcSlope = [Double](repeating: 0, count: count + 1)
        var angle = [Double](repeating: 0, count: count + 1)
        var angleSlope = [Double](repeating: 0, count: count + 1)

        // 起点相对内半径的累计量（低半径在内半径之内时为负）。
        radiiValues[0] = lowRadiusMm
        if lowRadiusMm >= inner {
            guard let offset = integrate(inner, lowRadiusMm) else { return nil }
            arc[0] = offset.arc
            angle[0] = offset.angle
        } else {
            guard let offset = integrate(lowRadiusMm, inner) else { return nil }
            arc[0] = -offset.arc
            angle[0] = -offset.angle
        }
        let first = integrands(lowRadiusMm)
        arcSlope[0] = first.arc
        angleSlope[0] = first.angle

        for interval in 0..<count {
            let intervalStart = lowRadiusMm + Double(interval) * step
            let intervalEnd = intervalStart + step
            guard let delta = integrate(intervalStart, intervalEnd) else { return nil }
            radiiValues[interval + 1] = intervalEnd
            arc[interval + 1] = arc[interval] + delta.arc
            angle[interval + 1] = angle[interval] + delta.angle
            let slope = integrands(intervalEnd)
            arcSlope[interval + 1] = slope.arc
            angleSlope[interval + 1] = slope.angle
        }

        radii = radiiValues
        arcValues = arc
        arcSlopes = arcSlope
        angleValues = angle
        angleSlopes = angleSlope
    }

    func arc(at radius: Double) -> (value: Double, slope: Double)? {
        interpolate(radius: radius, values: arcValues, slopes: arcSlopes)
    }

    func angle(at radius: Double) -> (value: Double, slope: Double)? {
        interpolate(radius: radius, values: angleValues, slopes: angleSlopes)
    }

    func radius(forArc target: Double) -> Double? {
        guard target.isFinite else { return nil }
        guard target >= arcValues[0], target <= arcValues[arcValues.count - 1] else { return nil }
        var low = 0
        var high = arcValues.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if arcValues[middle] <= target { low = middle } else { high = middle - 1 }
        }
        let index = min(low, arcValues.count - 2)
        var radius = radii[index] + (target - arcValues[index]) / max(arcSlopes[index], 1e-30)
        for _ in 0..<8 {
            guard let interpolated = arc(at: radius) else { break }
            guard interpolated.slope.isFinite, interpolated.slope != 0 else { break }
            let error = interpolated.value - target
            radius -= error / interpolated.slope
            if abs(error) < 1e-12 { break }
        }
        guard radius.isFinite, radius >= lowRadiusMm, radius <= highRadiusMm else { return nil }
        return radius
    }

    private func interpolate(
        radius: Double,
        values: [Double],
        slopes: [Double]
    ) -> (value: Double, slope: Double)? {
        guard radius.isFinite, radius >= lowRadiusMm, radius <= highRadiusMm else { return nil }
        var index = Int(((radius - lowRadiusMm) / step).rounded(.down))
        index = min(max(index, 0), values.count - 2)
        let intervalStart = radii[index]
        let t = (radius - intervalStart) / step
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        let value = h00 * values[index] + h10 * step * slopes[index]
            + h01 * values[index + 1] + h11 * step * slopes[index + 1]
        let d00 = 6 * t2 - 6 * t
        let d10 = 3 * t2 - 4 * t + 1
        let d01 = -6 * t2 + 6 * t
        let d11 = 3 * t2 - 2 * t
        let slope = (d00 * values[index] + d01 * values[index + 1]) / step
            + d10 * slopes[index] + d11 * slopes[index + 1]
        guard value.isFinite, slope.isFinite else { return nil }
        return (value, slope)
    }
}
