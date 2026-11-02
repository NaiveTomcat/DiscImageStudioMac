import DiscImageCore
import Foundation

/// DVD 阿基米德螺旋（等螺距，或三次轨距分布）。
///
/// 只负责「弧长 → 半径 / 累计角度」这一件事，绘图时每个 payload 码字都要问它一次。
///
/// 几何约定与源项目 `DvdTrackGeometry` 一致：
/// - 总轨道长 `L = sectors × 38688 × bitLengthNm × 1e-6`（mm）；
/// - 等螺距：`dr/dθ = b`，`L = (P(ro) − P(ri)) / b`，其中
///   `P(r) = 0.5·(r·√(r²+b²) + b²·asinh(r/b))`；
/// - 三次轨距：`dr/dθ = b·(1 + c1x + c2x² + c3x³)`，`x = (r−ri)/(ro−ri)`，
///   `b` 由总轨道长数值求解；节点表把弧长/角度/半径预先算好，查询走二分 + 线性插值。
///
/// 角度是**累计（未取模）**的，一圈 = 2π。DVD 的螺旋方向由调用方取负角度实现。
struct DvdSpiral: Sendable {
    let innerRadiusMm: Double
    let outerRadiusMm: Double
    let totalSectors: Int
    let trackLengthMm: Double
    let channelBitLengthMm: Double
    let isConstantPitch: Bool
    let totalAngleRadians: Double
    /// `dr/dθ` 的基准值（mm/rad）。等螺距时就是常数；三次轨距时是 `x=0` 处的值。
    let radialGrowthPerRadianMm: Double

    private struct Node: Sendable {
        let arcLengthMm: Double
        let radiusMm: Double
        let angleRadians: Double
    }

    // 三次轨距系数（等螺距时全为 0）
    private let pitchLinear: Double
    private let pitchQuadratic: Double
    private let pitchCubic: Double
    private let radialSpanMm: Double

    // 等螺距快速路径的缓存
    private let innerSquared: Double
    private let growthSquared: Double
    private let innerPrimitive: Double

    // 三次轨距的节点表
    private let nodes: [Node]

    private static let gauss8Nodes: [Double] = [
        -0.9602898564975363, -0.7966664774136267, -0.5255324099163290, -0.1834346424956498,
        0.1834346424956498, 0.5255324099163290, 0.7966664774136267, 0.9602898564975363,
    ]
    private static let gauss8Weights: [Double] = [
        0.1012285362903763, 0.2223810344533745, 0.3137066458778873, 0.3626837833783620,
        0.3626837833783620, 0.3137066458778873, 0.2223810344533745, 0.1012285362903763,
    ]

    init(geometry: DiscGeometry) throws {
        guard geometry.family == .dvd else {
            throw DiscError.invalidGeometry("DvdSpiral 只接受 DVD 几何（当前 \(geometry.family.displayNameZH)）")
        }
        try geometry.validate()
        innerRadiusMm = geometry.innerRadiusMm
        outerRadiusMm = geometry.outerRadiusMm
        totalSectors = geometry.sectors
        pitchLinear = geometry.pitchLinear
        pitchQuadratic = geometry.pitchQuadratic
        pitchCubic = geometry.pitchCubic
        radialSpanMm = geometry.outerRadiusMm - geometry.innerRadiusMm
        channelBitLengthMm = geometry.channelBitLengthNm * 1e-6
        trackLengthMm = Double(geometry.sectors)
            * Double(DvdConstants.channelBitsPerSector)
            * channelBitLengthMm
        guard trackLengthMm.isFinite, trackLengthMm > outerRadiusMm - innerRadiusMm else {
            throw DiscError.invalidGeometry(
                "轨道总长 \(trackLengthMm) mm 不足以从 \(innerRadiusMm) mm 走到 \(outerRadiusMm) mm"
            )
        }

        if !geometry.hasCubicPitch {
            isConstantPitch = true
            nodes = []
            let growth = try Self.solveConstantGrowth(
                inner: innerRadiusMm,
                outer: outerRadiusMm,
                trackLength: trackLengthMm
            )
            radialGrowthPerRadianMm = growth
            totalAngleRadians = (outerRadiusMm - innerRadiusMm) / growth
            innerSquared = innerRadiusMm * innerRadiusMm
            growthSquared = growth * growth
            innerPrimitive = Self.primitive(innerRadiusMm, growth)
        } else {
            isConstantPitch = false
            let built = try Self.buildCubicTable(
                inner: innerRadiusMm,
                outer: outerRadiusMm,
                trackLength: trackLengthMm,
                linear: geometry.pitchLinear,
                quadratic: geometry.pitchQuadratic,
                cubic: geometry.pitchCubic
            )
            radialGrowthPerRadianMm = built.growth
            totalAngleRadians = built.totalAngle
            nodes = built.nodes
            innerSquared = 0
            growthSquared = 0
            innerPrimitive = 0
        }
    }

    /// 平均螺距（mm）：`2π·(dr/dθ)` 的基准值。
    var pitchMm: Double {
        2 * .pi * radialGrowthPerRadianMm
    }

    /// 弧长（mm）→（半径 mm，累计角度 rad）。
    func atArcLength(_ arcLengthMm: Double) -> (radiusMm: Double, angleRadians: Double) {
        if isConstantPitch {
            let radius = radiusAtConstantArcLength(arcLengthMm)
            return (radius, (radius - innerRadiusMm) / radialGrowthPerRadianMm)
        }
        guard arcLengthMm.isFinite else { return (innerRadiusMm, 0) }
        if arcLengthMm <= 0 { return (innerRadiusMm, 0) }
        if arcLengthMm >= trackLengthMm { return (outerRadiusMm, totalAngleRadians) }
        // 二分找最后一个 arc <= 目标值的节点。
        var low = 0
        var high = nodes.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if nodes[middle].arcLengthMm <= arcLengthMm {
                low = middle
            } else {
                high = middle - 1
            }
        }
        let start = nodes[low]
        let end = low + 1 < nodes.count ? nodes[low + 1] : start
        let span = end.arcLengthMm - start.arcLengthMm
        let fraction = span > 0 ? (arcLengthMm - start.arcLengthMm) / span : 0
        return (
            start.radiusMm + fraction * (end.radiusMm - start.radiusMm),
            start.angleRadians + fraction * (end.angleRadians - start.angleRadians)
        )
    }

    /// 弧长 → 半径（只取半径的便捷入口）。
    func radiusAtArcLength(_ arcLengthMm: Double) -> Double {
        atArcLength(arcLengthMm).radiusMm
    }

    // MARK: - 绘图热循环的增量推进

    /// 归一化半径处三次轨距多项式的值 `1 + c1x + c2x² + c3x³`。
    func shape(atRadius radiusMm: Double) -> Double {
        guard radialSpanMm > 0 else { return 1 }
        let x = (radiusMm - innerRadiusMm) / radialSpanMm
        return ((pitchCubic * x + pitchQuadratic) * x + pitchLinear) * x + 1
    }

    /// 从 `radiusMm` 前进 `deltaArcLengthMm` 后（半径，累计角度增量）。
    ///
    /// 这是绘图热循环用的局部线性化推进：单步弧长远小于半径（几十微米），
    /// 二阶误差在 1e-16 mm 量级；每个 ECC Block 开始时会用 `atArcLength`
    /// 精确重开，所以误差不会跨 Block 累积。
    func advance(
        radiusMm: Double,
        deltaArcLengthMm: Double
    ) -> (radiusMm: Double, deltaAngleRadians: Double) {
        let slope: Double
        if isConstantPitch {
            slope = radialGrowthPerRadianMm
        } else {
            slope = radialGrowthPerRadianMm * shape(atRadius: radiusMm)
        }
        let ratio = radiusMm / slope
        let derivative = 1 / (1 + ratio * ratio).squareRoot()
        let next = min(max(radiusMm + deltaArcLengthMm * derivative, innerRadiusMm), outerRadiusMm)
        let deltaRadius = next - radiusMm
        return (next, deltaRadius / slope)
    }

    // MARK: - 等螺距

    /// 由总轨道长反解 `dr/dθ = b`：`L(b) = (P(ro)−P(ri))/b` 对 b 单调递减。
    private static func solveConstantGrowth(inner: Double, outer: Double, trackLength: Double) throws -> Double {
        var low = 1e-15
        var high = max(outer, 1.0)
        while constantArcLength(inner: inner, outer: outer, growth: high) > trackLength {
            high *= 2
            if high > 1e12 {
                throw DiscError.invalidGeometry("DVD 螺距反解失败（轨道长度 \(trackLength) mm）")
            }
        }
        for _ in 0..<120 {
            let middle = (low + high) / 2
            if constantArcLength(inner: inner, outer: outer, growth: middle) > trackLength {
                low = middle
            } else {
                high = middle
            }
        }
        let growth = (low + high) / 2
        guard growth.isFinite, growth > 0 else {
            throw DiscError.invalidGeometry("DVD 螺距必须是正数")
        }
        return growth
    }

    private static func constantArcLength(inner: Double, outer: Double, growth: Double) -> Double {
        (primitive(outer, growth) - primitive(inner, growth)) / growth
    }

    private static func primitive(_ radius: Double, _ growth: Double) -> Double {
        0.5 * (radius * (radius * radius + growth * growth).squareRoot()
            + growth * growth * asinh(radius / growth))
    }

    private func radiusAtConstantArcLength(_ arcLengthMm: Double) -> Double {
        guard arcLengthMm.isFinite else { return innerRadiusMm }
        if arcLengthMm <= 0 { return innerRadiusMm }
        if arcLengthMm >= trackLengthMm { return outerRadiusMm }
        let growth = radialGrowthPerRadianMm
        var radius = min(max((innerSquared + 2 * growth * arcLengthMm).squareRoot(), innerRadiusMm), outerRadiusMm)
        for _ in 0..<4 {
            let root = (radius * radius + growthSquared).squareRoot()
            let primitive = 0.5 * (radius * root + growthSquared * asinh(radius / growth))
            let error = (primitive - innerPrimitive) / growth - arcLengthMm
            let derivative = root / growth
            let next = min(max(radius - error / derivative, innerRadiusMm), outerRadiusMm)
            if next == radius { break }
            radius = next
        }
        return radius
    }

    // MARK: - 三次轨距

    private struct CubicTable {
        let growth: Double
        let totalAngle: Double
        let nodes: [Node]
    }

    private static func buildCubicTable(
        inner: Double,
        outer: Double,
        trackLength: Double,
        linear: Double,
        quadratic: Double,
        cubic: Double
    ) throws -> CubicTable {
        let radialSpan = outer - inner
        func shape(_ radius: Double) -> Double {
            let x = (radius - inner) / radialSpan
            return ((cubic * x + quadratic) * x + linear) * x + 1
        }

        // b 的下界：把轨道当「无限薄」反算，实际长度一定不小于薄轨道长度。
        let thinArea = integrate(from: inner, to: outer, intervals: 256) { radius in
            radius / shape(radius)
        }
        guard thinArea.isFinite, thinArea > 0 else {
            throw DiscError.invalidGeometry("DVD 三次轨距的等效面积不可解析")
        }
        var low = thinArea / trackLength
        var high = max(low * 1.001, low + 1e-9)
        func length(_ growth: Double) -> Double {
            integrate(from: inner, to: outer, intervals: 256) { radius in
                let z = radius / (growth * shape(radius))
                return (1 + z * z).squareRoot()
            }
        }
        var guardCount = 0
        while length(high) > trackLength {
            high *= 2
            guardCount += 1
            if guardCount > 200 {
                throw DiscError.invalidGeometry("DVD 三次轨距反解失败（轨道长度 \(trackLength) mm）")
            }
        }
        for _ in 0..<80 {
            let middle = (low + high) / 2
            if length(middle) > trackLength {
                low = middle
            } else {
                high = middle
            }
        }
        let growth = (low + high) / 2
        guard growth.isFinite, growth > 0 else {
            throw DiscError.invalidGeometry("DVD 三次轨距的 b 必须是正数")
        }

        // 节点表：等半径间距，累计弧长与累计角度。
        let count = 4096
        var nodes = [Node]()
        nodes.reserveCapacity(count + 1)
        nodes.append(Node(arcLengthMm: 0, radiusMm: inner, angleRadians: 0))
        var arc = 0.0
        var angle = 0.0
        let step = radialSpan / Double(count)
        for index in 0..<count {
            let r0 = inner + step * Double(index)
            let r1 = inner + step * Double(index + 1)
            let middle = (r0 + r1) / 2
            let half = (r1 - r0) / 2
            var deltaArc = 0.0
            var deltaAngle = 0.0
            for node in 0..<8 {
                let radius = middle + half * gauss8Nodes[node]
                let localShape = shape(radius)
                let z = radius / (growth * localShape)
                deltaArc += gauss8Weights[node] * half * (1 + z * z).squareRoot()
                deltaAngle += gauss8Weights[node] * half / (growth * localShape)
            }
            arc += deltaArc
            angle += deltaAngle
            nodes.append(Node(arcLengthMm: arc, radiusMm: r1, angleRadians: angle))
        }
        guard arc.isFinite, arc > 0, angle.isFinite, angle > 0 else {
            throw DiscError.invalidGeometry("DVD 三次轨距的节点表无法解析")
        }
        // 抹掉最后几位舍入误差，让进度精确落在外半径。
        let scale = trackLength / arc
        if abs(scale - 1) > 1e-12 {
            nodes = nodes.map { Node(arcLengthMm: $0.arcLengthMm * scale, radiusMm: $0.radiusMm, angleRadians: $0.angleRadians) }
        }
        return CubicTable(growth: growth, totalAngle: angle, nodes: nodes)
    }

    /// 复合 8 点 Gauss-Legendre 积分。
    private static func integrate(
        from start: Double,
        to end: Double,
        intervals: Int,
        _ function: (Double) -> Double
    ) -> Double {
        let step = (end - start) / Double(intervals)
        var sum = 0.0
        for index in 0..<intervals {
            let middle = start + (Double(index) + 0.5) * step
            let half = step / 2
            for node in 0..<8 {
                sum += gauss8Weights[node] * half * function(middle + half * gauss8Nodes[node])
            }
        }
        return sum
    }
}
