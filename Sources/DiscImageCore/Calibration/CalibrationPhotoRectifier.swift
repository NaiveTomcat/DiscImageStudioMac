import Foundation

/// 照片像素 ↔ 盘面毫米 的投影变换（单应矩阵，y 向下）。
///
/// 内部保存的 `matrix9` 是**盘面 → 照片**的 3×3 行主序矩阵（已按最大元素归一），
/// 与上游 `CalibrationPhotoTransform` 的序列化形式一致；反变换由它求逆得到。
public struct CalibrationPhotoTransform: Equatable, Sendable {
    private let discToSource: [Double]
    private let sourceToDisc: [Double]

    /// - Parameter discToSourceMatrix9: 盘面毫米 → 照片像素 的 3×3 行主序矩阵。
    public init(discToSourceMatrix9: [Double]) throws {
        guard discToSourceMatrix9.count == 9,
              discToSourceMatrix9.allSatisfy({ $0.isFinite }) else {
            throw DiscError.invalidGeometry("照片变换必须包含 9 个有限数值。")
        }
        let scale = discToSourceMatrix9.map(abs).max() ?? 0
        guard scale > 0 else {
            throw DiscError.invalidGeometry("照片变换不可逆。")
        }
        let normalized = discToSourceMatrix9.map { $0 / scale }
        self.discToSource = normalized
        self.sourceToDisc = try Self.inverse(of: normalized)
    }

    /// 盘面 → 照片 的 3×3 行主序矩阵（可直接存进会话）。
    public var matrix9: [Double] { discToSource }

    public var discToSourceMatrix9: [Double] { discToSource }

    public var sourceToDiscMatrix9: [Double] { sourceToDisc }

    /// 照片像素 → 盘面毫米。投影地平线附近返回 NaN（可先用 `isValidForDisc` 判断）。
    public func sourceToDisc(_ point: CalibrationPoint) -> CalibrationPoint {
        Self.map(sourceToDisc, point)
    }

    /// 盘面毫米 → 照片像素。
    public func discToSource(_ point: CalibrationPoint) -> CalibrationPoint {
        Self.map(discToSource, point)
    }

    /// 整个实体盘面是否都落在投影地平线的同一侧（拍摄角度极端时会被拒绝）。
    public func isValidForDisc(_ physicalOuterRadiusMm: Double) -> Bool {
        guard physicalOuterRadiusMm.isFinite, physicalOuterRadiusMm > 0 else { return false }
        let variation = physicalOuterRadiusMm
            * (discToSource[6] * discToSource[6] + discToSource[7] * discToSource[7]).squareRoot()
        return abs(discToSource[8]) > variation * 1.02 + 1e-12
    }

    // MARK: - 内部

    static func map(_ matrix: [Double], _ point: CalibrationPoint) -> CalibrationPoint {
        guard point.xMm.isFinite, point.yMm.isFinite else {
            return CalibrationPoint(xMm: .nan, yMm: .nan)
        }
        let divisor = matrix[6] * point.xMm + matrix[7] * point.yMm + matrix[8]
        let scale = abs(matrix[6] * point.xMm) + abs(matrix[7] * point.yMm) + abs(matrix[8])
        guard abs(divisor) > max(1e-15, scale * 1e-12) else {
            return CalibrationPoint(xMm: .nan, yMm: .nan)
        }
        let x = (matrix[0] * point.xMm + matrix[1] * point.yMm + matrix[2]) / divisor
        let y = (matrix[3] * point.xMm + matrix[4] * point.yMm + matrix[5]) / divisor
        guard x.isFinite, y.isFinite else {
            return CalibrationPoint(xMm: .nan, yMm: .nan)
        }
        return CalibrationPoint(xMm: x, yMm: y)
    }

    static func inverse(of matrix: [Double]) throws -> [Double] {
        var result: [Double] = [
            matrix[4] * matrix[8] - matrix[5] * matrix[7],
            matrix[2] * matrix[7] - matrix[1] * matrix[8],
            matrix[1] * matrix[5] - matrix[2] * matrix[4],
            matrix[5] * matrix[6] - matrix[3] * matrix[8],
            matrix[0] * matrix[8] - matrix[2] * matrix[6],
            matrix[2] * matrix[3] - matrix[0] * matrix[5],
            matrix[3] * matrix[7] - matrix[4] * matrix[6],
            matrix[1] * matrix[6] - matrix[0] * matrix[7],
            matrix[0] * matrix[4] - matrix[1] * matrix[3],
        ]
        let determinant = matrix[0] * result[0] + matrix[1] * result[3] + matrix[2] * result[6]
        let determinantScale = abs(matrix[0] * result[0])
            + abs(matrix[1] * result[3]) + abs(matrix[2] * result[6])
        guard determinant.isFinite,
              abs(determinant) > max(1e-20, determinantScale * 1e-12) else {
            throw DiscError.invalidGeometry("照片变换退化，无法恢复盘面坐标。")
        }
        for index in result.indices { result[index] /= determinant }
        return result
    }
}

/// 参数：把同一平面上的两条已知同心圆（实体外缘 + 中心孔）联合拟合成一个单应矩阵。
///
/// 尺度来自所选盘片规格与标准中心孔尺寸，不需要手动测量；两条椭圆的几何中心
/// 不能直接当作盘心，单独拉圆一个椭圆也不能完全消除透视形变。
public enum CalibrationPhotoRectifier {
    /// 拟合结果。
    public struct Result: Sendable {
        public var transform: CalibrationPhotoTransform
        /// 外缘与内缘拟合残差中的较大者（像素）。
        public var rmsPixels: Double
        public var outerRmsPixels: Double
        public var holeRmsPixels: Double
        public var message: String
    }

    private struct Datum {
        let x: Double
        let y: Double
        let radius: Double
        let weight: Double
    }

    /// 联合拟合两条实体轮廓，返回照片 ↔ 盘面变换与像素残差。
    ///
    /// - Parameters:
    ///   - outerEdge: 实体外缘上的点（照片像素，至少 5 个且分散）。
    ///   - centerHole: 中心孔边缘上的点（照片像素，至少 5 个且分散）。
    ///   - discSize: 12 cm / 8 cm 实体盘片规格。
    public static func fit(
        outerEdge: [CalibrationPoint],
        centerHole: [CalibrationPoint],
        discSize: CalibrationDiscSize
    ) throws -> (transform: CalibrationPhotoTransform, rmsPixels: Double) {
        let detailed = try fitDetailed(outerEdge: outerEdge, centerHole: centerHole, discSize: discSize)
        return (detailed.transform, detailed.rmsPixels)
    }

    /// 与 `fit` 相同，但额外返回两条轮廓各自的残差和面向用户的说明。
    public static func fitDetailed(
        outerEdge: [CalibrationPoint],
        centerHole: [CalibrationPoint],
        discSize: CalibrationDiscSize
    ) throws -> Result {
        let physicalOuterRadiusMm = discSize.physicalOuterRadiusMm
        let physicalHoleRadiusMm = discSize.physicalHoleRadiusMm

        guard outerEdge.count >= 5, outerEdge.count <= 256,
              centerHole.count >= 5, centerHole.count <= 256 else {
            throw DiscError.invalidGeometry("外缘和内缘各需要至少 5 个分散的点，且每条轮廓不超过 256 个点。")
        }
        guard (outerEdge + centerHole).allSatisfy({ $0.xMm.isFinite && $0.yMm.isFinite }) else {
            throw DiscError.invalidGeometry("轮廓中存在无效坐标。")
        }

        let minX = outerEdge.map(\.xMm).min()!
        let maxX = outerEdge.map(\.xMm).max()!
        let minY = outerEdge.map(\.yMm).min()!
        let maxY = outerEdge.map(\.yMm).max()!
        let centerX = (maxX + minX) / 2
        let centerY = (maxY + minY) / 2
        let sourceScale = max(maxX - minX, maxY - minY) / 2
        guard sourceScale.isFinite, sourceScale >= 5 else {
            throw DiscError.invalidGeometry("照片中的盘片过小，无法稳定矫正。")
        }

        func normalized(_ points: [CalibrationPoint]) -> [CalibrationPoint] {
            points.map {
                CalibrationPoint(
                    xMm: ($0.xMm - centerX) / sourceScale,
                    yMm: ($0.yMm - centerY) / sourceScale
                )
            }
        }
        let outer = normalized(outerEdge)
        let hole = normalized(centerHole)
        guard isSpread(outer), isSpread(hole) else {
            throw DiscError.invalidGeometry("轮廓点重复或接近一条直线，请沿外缘和内缘分别分散布点。")
        }
        guard let initial = initialAffineEllipse(outer) else {
            throw DiscError.invalidGeometry("外缘轮廓无法形成稳定椭圆，请核对实体外缘上的点。")
        }

        let holeExtent = hole.map { point -> Double in
            let u = exp(initial[0]) * point.xMm + initial[1] * point.yMm + initial[2]
            let v = exp(initial[3]) * point.yMm + initial[4]
            return (u * u + v * v).squareRoot()
        }.reduce(0, +) / Double(hole.count)
        guard holeExtent >= 0.015, holeExtent <= 0.9 else {
            throw DiscError.invalidGeometry("内缘轮廓与外缘位置不符，请确认选中的是贯通的实体内缘，而非盘面的印刷圆环。")
        }

        let ratio = physicalHoleRadiusMm / physicalOuterRadiusMm
        let data = outer.map {
            Datum(x: $0.xMm, y: $0.yMm, radius: 1, weight: 1.0 / Double(outer.count).squareRoot())
        } + hole.map {
            Datum(x: $0.xMm, y: $0.yMm, radius: ratio, weight: 1.0 / Double(hole.count).squareRoot())
        }

        var seeds: [[Double]] = []
        if let joint = initialJointProjection(initial, hole: hole, ratio: ratio) {
            seeds.append(joint)
        }
        // 只做外缘椭圆仿射初始化不算矫正结果：7 个自由参数要对**两条**圆同时优化。
        for offset in [(0.0, 0.0), (0.25, 0.0), (-0.25, 0.0), (0.0, 0.25), (0.0, -0.25)] {
            var seed = initial
            seed[5] = offset.0
            seed[6] = offset.1
            seeds.append(seed)
        }

        var best: [Double]?
        var bestCost = Double.infinity
        for seed in seeds {
            let (solution, cost) = optimize(seed, data: data)
            if cost < bestCost {
                best = solution
                bestCost = cost
            }
            if bestCost < 1e-20 { break }
        }
        guard let best, bestCost.isFinite else {
            throw DiscError.invalidGeometry("两条轮廓不能得到有效的联合投影，请检查布点。")
        }

        let a = exp(best[0])
        let b = best[1]
        let c = best[2]
        let d = exp(best[3])
        let e = best[4]
        let g = best[5]
        let h = best[6]
        let radius = physicalOuterRadiusMm
        let sourceToDisc: [Double] = [
            radius * a / sourceScale,
            radius * b / sourceScale,
            radius * (c - (a * centerX + b * centerY) / sourceScale),
            0,
            radius * d / sourceScale,
            radius * (e - d * centerY / sourceScale),
            g / sourceScale,
            h / sourceScale,
            1 - (g * centerX + h * centerY) / sourceScale,
        ]
        let transform = try CalibrationPhotoTransform(
            discToSourceMatrix9: CalibrationPhotoTransform.inverse(of: sourceToDisc)
        )
        guard transform.isValidForDisc(radius) else {
            throw DiscError.invalidGeometry("拍摄角度或轮廓对应关系导致投影退化，请换角度拍摄或重新布点。")
        }
        guard coversCircle(outerEdge, transform: transform),
              coversCircle(centerHole, transform: transform) else {
            throw DiscError.invalidGeometry("轮廓点集中在局部，请在两条完整圆周的不同方向补点。")
        }

        let outerResidual = residual(outerEdge, transform: transform, radius: radius)
        let holeResidual = residual(centerHole, transform: transform, radius: physicalHoleRadiusMm)
        let tolerance = max(2, sourceScale * 0.006)
        guard outerResidual.rms <= tolerance, holeResidual.rms <= tolerance,
              max(outerResidual.maximum, holeResidual.maximum) <= tolerance * 3 else {
            throw DiscError.invalidGeometry(
                "两条实体轮廓无法同时吻合：外缘误差 \(format(outerResidual.rms)) px，"
                    + "内缘误差 \(format(holeResidual.rms)) px。请检查内缘、外缘与盘片尺寸。"
            )
        }
        return Result(
            transform: transform,
            rmsPixels: max(outerResidual.rms, holeResidual.rms),
            outerRmsPixels: outerResidual.rms,
            holeRmsPixels: holeResidual.rms,
            message: "已联合校正外缘与内缘。轮廓误差：外缘 \(format(outerResidual.rms)) px，"
                + "内缘 \(format(holeResidual.rms)) px。请继续核对两条轮廓。"
        )
    }

    // MARK: - 初始化

    private static func isSpread(_ points: [CalibrationPoint]) -> Bool {
        for i in points.indices {
            for j in 0..<i {
                let dx = points[i].xMm - points[j].xMm
                let dy = points[i].yMm - points[j].yMm
                if dx * dx + dy * dy < 1e-10 { return false }
            }
        }
        let count = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.xMm } / count
        let meanY = points.reduce(0) { $0 + $1.yMm } / count
        var xx = 0.0
        var yy = 0.0
        var xy = 0.0
        for point in points {
            let dx = point.xMm - meanX
            let dy = point.yMm - meanY
            xx += dx * dx
            yy += dy * dy
            xy += dx * dy
        }
        return xx + yy > 1e-6 && xx * yy - xy * xy > (xx + yy) * (xx + yy) * 1e-5
    }

    /// 外缘椭圆的仿射初值：返回 [log a, b, c, log d, e, g, h]（g/h 先置 0）。
    private static func initialAffineEllipse(_ points: [CalibrationPoint]) -> [Double]? {
        var normal = [[Double]](repeating: [Double](repeating: 0, count: 5), count: 5)
        var right = [Double](repeating: 0, count: 5)
        let count = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.xMm } / count
        let meanY = points.reduce(0) { $0 + $1.yMm } / count
        for point in points {
            let x = point.xMm - meanX
            let y = point.yMm - meanY
            let row = [x * x, 2 * x * y, y * y, x, y]
            for i in 0..<5 {
                right[i] += row[i]
                for j in 0..<5 { normal[i][j] += row[i] * row[j] }
            }
        }
        guard var q = solve(normal, right) else { return nil }
        let determinant = q[0] * q[2] - q[1] * q[1]
        guard q[0] > 0, q[2] > 0, determinant > 1e-10 else { return nil }
        let cx = -(q[2] * q[3] - q[1] * q[4]) / (2 * determinant)
        let cy = -(q[0] * q[4] - q[1] * q[3]) / (2 * determinant)
        let k = 1 + q[0] * cx * cx + 2 * q[1] * cx * cy + q[2] * cy * cy
        guard k > 0 else { return nil }
        let a = (q[0] / k).squareRoot()
        let b = q[1] / (k * a)
        let dSquared = q[2] / k - b * b
        guard dSquared > 1e-10 else { return nil }
        let d = dSquared.squareRoot()
        q = [log(a), b, -a * (cx + meanX) - b * (cy + meanY), log(d), -d * (cy + meanY), 0, 0]
        return q
    }

    private static func initialJointProjection(
        _ outerAffine: [Double],
        hole: [CalibrationPoint],
        ratio: Double
    ) -> [Double]? {
        let a = exp(outerAffine[0])
        let b = outerAffine[1]
        let c = outerAffine[2]
        let d = exp(outerAffine[3])
        let e = outerAffine[4]
        let normalizedHole = hole.map {
            CalibrationPoint(xMm: a * $0.xMm + b * $0.yMm + c, yMm: d * $0.yMm + e)
        }
        guard let holeEllipse = initialAffineEllipse(normalizedHole) else { return nil }
        let centerY = -holeEllipse[4] / exp(holeEllipse[3])
        let centerX = -(holeEllipse[2] + holeEllipse[1] * centerY) / exp(holeEllipse[0])
        let length = (centerX * centerX + centerY * centerY).squareRoot()
        if length < 1e-10 { return outerAffine }
        guard length < 0.95 else { return nil }

        // 外椭圆变成单位圆之后，还剩一个保圆的投影平移。对半径 r 的同心圆，
        // 其投影椭圆中心长度为 c = v(1−r²)/(1−r²v²)；用实测椭圆中心与已知半径比反解 v。
        let r2 = ratio * ratio
        let oneMinusR2 = 1 - r2
        let v = 2 * length
            / (oneMinusR2 + (oneMinusR2 * oneMinusR2 + 4 * length * length * r2).squareRoot())
        guard v < 0.98 else { return nil }
        let nx = centerX / length
        let ny = centerY / length
        let vx = v * nx
        let vy = v * ny
        let gamma = 1 / (1 - v * v).squareRoot()
        let ax = 1 + (gamma - 1) * nx * nx
        let ay = 1 + (gamma - 1) * ny * ny
        let cross = (gamma - 1) * nx * ny
        let matrix: [Double] = [
            ax * a, ax * b + cross * d, ax * c + cross * e - gamma * vx,
            cross * a, cross * b + ay * d, cross * c + ay * e - gamma * vy,
            -gamma * vx * a, -gamma * (vx * b + vy * d), gamma * (1 - vx * c - vy * e),
        ]
        // 只固定面内自由旋转：把第一个分子列转到 +X，给优化器一个无冗余的七参数形式。
        let firstLength = (matrix[0] * matrix[0] + matrix[3] * matrix[3]).squareRoot()
        guard firstLength > 1e-12, matrix[8] != 0 else { return nil }
        let cosine = matrix[0] / firstLength
        let sine = matrix[3] / firstLength
        let scale = matrix[8]
        let newA = firstLength / scale
        let newB = (cosine * matrix[1] + sine * matrix[4]) / scale
        let newC = (cosine * matrix[2] + sine * matrix[5]) / scale
        let newD = (-sine * matrix[1] + cosine * matrix[4]) / scale
        let newE = (-sine * matrix[2] + cosine * matrix[5]) / scale
        guard newA > 0, newD > 0 else { return nil }
        return [log(newA), newB, newC, log(newD), newE, matrix[6] / scale, matrix[7] / scale]
    }

    // MARK: - 优化

    private static func optimize(
        _ initial: [Double],
        data: [Datum]
    ) -> (parameters: [Double], cost: Double) {
        var parameters = initial
        var residual = evaluate(parameters, data: data)
        var cost = residual.reduce(0) { $0 + $1 * $1 }
        var damping = 1e-3
        var iteration = 0
        while iteration < 120, cost.isFinite {
            iteration += 1
            var derivatives = [[Double]](repeating: [], count: 7)
            for axis in 0..<7 {
                let step = 1e-5 * max(1, abs(parameters[axis]))
                var shifted = parameters
                shifted[axis] += step
                let sample = evaluate(shifted, data: data)
                derivatives[axis] = sample.enumerated().map { index, value in
                    (value - residual[index]) / step
                }
            }
            var normal = [[Double]](repeating: [Double](repeating: 0, count: 7), count: 7)
            var right = [Double](repeating: 0, count: 7)
            for i in 0..<7 {
                for n in data.indices { right[i] -= derivatives[i][n] * residual[n] }
                for j in 0..<7 {
                    for n in data.indices { normal[i][j] += derivatives[i][n] * derivatives[j][n] }
                }
                normal[i][i] += damping * max(normal[i][i], 1e-8)
            }
            guard let delta = solve(normal, right) else { break }
            let candidate = parameters.enumerated().map { $0.element + delta[$0.offset] }
            let candidateResidual = evaluate(candidate, data: data)
            let candidateCost = candidateResidual.reduce(0) { $0 + $1 * $1 }
            if candidateCost < cost {
                let improvement = cost - candidateCost
                parameters = candidate
                residual = candidateResidual
                cost = candidateCost
                damping = max(1e-10, damping / 3)
                if cost < 1e-22 || improvement < max(1e-22, cost * 1e-10) { break }
            } else {
                damping *= 10
                if damping > 1e12 { break }
            }
        }
        return (parameters, cost)
    }

    private static func evaluate(_ parameters: [Double], data: [Datum]) -> [Double] {
        if parameters.contains(where: { !$0.isFinite })
            || abs(parameters[0]) > 7 || abs(parameters[3]) > 7
            || abs(parameters[5]) > 10 || abs(parameters[6]) > 10 {
            return [Double](repeating: .infinity, count: data.count)
        }
        let a = exp(parameters[0])
        let d = exp(parameters[3])
        let determinant = a * d - a * parameters[4] * parameters[6]
            + parameters[1] * parameters[4] * parameters[5] - parameters[2] * d * parameters[5]
        let horizonX = -d * parameters[5]
        let horizonY = parameters[1] * parameters[5] - a * parameters[6]
        if determinant <= a * d * 1e-4
            || a * d <= (horizonX * horizonX + horizonY * horizonY).squareRoot() * 1.02 {
            return [Double](repeating: .infinity, count: data.count)
        }
        var result = [Double](repeating: 0, count: data.count)
        for (index, point) in data.enumerated() {
            let u = a * point.x + parameters[1] * point.y + parameters[2]
            let v = d * point.y + parameters[4]
            let w = parameters[5] * point.x + parameters[6] * point.y + 1
            let r2 = point.radius * point.radius
            let gx = 2 * (a * u - r2 * parameters[5] * w)
            let gy = 2 * (parameters[1] * u + d * v - r2 * parameters[6] * w)
            let gradient = (gx * gx + gy * gy).squareRoot()
            result[index] = w <= 0.03 || gradient < 1e-12
                ? .infinity
                : (u * u + v * v - r2 * w * w) / gradient * point.weight
        }
        return result
    }

    private static func solve(_ matrix: [[Double]], _ right: [Double]) -> [Double]? {
        let size = right.count
        var a = matrix
        var b = right
        for column in 0..<size {
            var pivot = column
            for row in (column + 1)..<size where abs(a[row][column]) > abs(a[pivot][column]) {
                pivot = row
            }
            guard a[pivot][column].isFinite, abs(a[pivot][column]) >= 1e-15 else { return nil }
            if pivot != column {
                a.swapAt(column, pivot)
                b.swapAt(column, pivot)
            }
            for row in (column + 1)..<size {
                let multiplier = a[row][column] / a[column][column]
                for j in (column + 1)..<size { a[row][j] -= multiplier * a[column][j] }
                b[row] -= multiplier * b[column]
            }
        }
        var result = [Double](repeating: 0, count: size)
        for index in stride(from: size - 1, through: 0, by: -1) {
            var value = b[index]
            for j in (index + 1)..<size { value -= a[index][j] * result[j] }
            result[index] = value / a[index][index]
            if !result[index].isFinite { return nil }
        }
        return result
    }

    // MARK: - 残差

    private static func coversCircle(
        _ points: [CalibrationPoint],
        transform: CalibrationPhotoTransform
    ) -> Bool {
        let angles = points.map { transform.sourceToDisc($0).angleRadians }.sorted()
        guard let first = angles.first, let last = angles.last else { return false }
        var maximumGap = first + 2 * .pi - last
        for index in 1..<angles.count {
            maximumGap = max(maximumGap, angles[index] - angles[index - 1])
        }
        return maximumGap < .pi * 0.95
    }

    /// 最近点残差：源点与投影圆之间的真实像素距离。
    private static func residual(
        _ points: [CalibrationPoint],
        transform: CalibrationPhotoTransform,
        radius: Double
    ) -> (rms: Double, maximum: Double) {
        var squared = 0.0
        var maximum = 0.0
        for source in points {
            let disc = transform.sourceToDisc(source)
            var angle = disc.angleRadians
            for _ in 0..<15 {
                let step = 1e-5
                let p = transform.discToSource(CalibrationPoint(
                    xMm: radius * cos(angle),
                    yMm: radius * sin(angle)
                ))
                let q = transform.discToSource(CalibrationPoint(
                    xMm: radius * cos(angle + step),
                    yMm: radius * sin(angle + step)
                ))
                let dx = (q.xMm - p.xMm) / step
                let dy = (q.yMm - p.yMm) / step
                let lengthSquared = dx * dx + dy * dy
                if lengthSquared < 1e-12 { break }
                let delta = min(max(((p.xMm - source.xMm) * dx + (p.yMm - source.yMm) * dy) / lengthSquared, -0.3), 0.3)
                angle -= delta
                if abs(delta) < 1e-10 { break }
            }
            let closest = transform.discToSource(CalibrationPoint(
                xMm: radius * cos(angle),
                yMm: radius * sin(angle)
            ))
            let dx = closest.xMm - source.xMm
            let dy = closest.yMm - source.yMm
            let distance = (dx * dx + dy * dy).squareRoot()
            squared += distance * distance
            maximum = max(maximum, distance)
        }
        return ((squared / Double(points.count)).squareRoot(), maximum)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
