import Foundation

/// 单条径向曲线的参数反推。
///
/// 行为规格见 `docs/CALIBRATION.md`（上游 `CalibrationCrossFitter` + `CalibrationCubicFitter`）：
/// - 只允许整条 trace 一个整数圈偏移，单点不能跳到别的臂或别的圈；
/// - 搜索框默认 ±0.02 mm，最优解贴边界时自动扩大到 ±0.1 / ±0.5 mm；
/// - 输出 rms / max / 离群点；平均 > 0.35 mm 或最大 > 0.8 mm 的候选不可应用；
/// - 点数不足（半径拟合 6 点；三次轨距 12 个不同半径且覆盖 60%）时只拟合半径并提示。
public enum CalibrationCrossFitter {
    private static let nearHalfTurnWarning =
        "有相邻曲线点的转角接近半圈，绕圈判断可能不可靠；请补点后复核。"
    private static let radiusBoundsWarning =
        "角度展开以相邻点之间没有遗漏整圈为前提；请对照完整曲线，在弯曲或绕行处补点后确认。"

    // MARK: - 公开入口

    /// 用会话里的生成快照反推实际盘片参数。
    ///
    /// - Parameters:
    ///   - session: 标定记录（至少要有生成快照；照片记录用于盘片尺寸校验）。
    ///   - points: 已矫正到盘面毫米坐标、从内到外排列的描点。
    ///   - options: 覆盖会话里保存的搜索选项。
    public static func fit(
        session: CalibrationSession,
        points: [CalibrationPoint],
        options: CalibrationFitOptions? = nil
    ) throws -> CalibrationFitResult {
        try session.validate()
        let fitOptions = options ?? session.fitOptions ?? .default
        try fitOptions.validate()
        try validate(points: points, session: session)

        let target = CalibrationParameters(
            geometry: session.generation.geometry,
            drawingStartSector: session.generation.drawingStartSector,
            drawingEndSectorExclusive: session.generation.drawingEndSectorExclusive
        )
        let band = target.outerRadiusMm - target.innerRadiusMm
        guard band > 0 else {
            throw DiscError.invalidGeometry("生成快照的内外半径无效。")
        }

        var inputWarnings: [String] = []
        let prepared = prepare(points: points, band: band, warnings: &inputWarnings)
        if let failure = prepared.failure {
            return .failed(inputWarnings + [failure])
        }
        let data = prepared.data
        guard data.count >= 6 else {
            return .failed(inputWarnings + [
                "请沿同一条曲线从内到外至少标出 6 个点，覆盖靠内、中间和靠外的位置。",
            ])
        }
        let coverage = (data.map(\.radius).max()! - data.map(\.radius).min()!) / band
        guard coverage >= 0.18 else {
            return .failed(inputWarnings + [
                "曲线覆盖范围太窄，无法稳定分离内外半径；请继续标出更靠内、外的曲线。",
            ])
        }

        let generatedGeometry: CalibrationTrackGeometry
        do {
            generatedGeometry = try CalibrationTrackGeometry(parameters: target)
        } catch {
            throw DiscError.invalidGeometry("生成快照的轨道模型无效，无法反推。")
        }

        // 观测点允许略超出生成环带，积分表范围要跟着放宽。
        let minimumRadius = data.map(\.radius).min()!
        let maximumRadius = data.map(\.radius).max()!
        let margin = max(
            1.0,
            maximumRadius - target.outerRadiusMm + 0.5,
            target.innerRadiusMm - minimumRadius + 0.5
        )
        let context = SolverContext(
            target: target,
            center: target,
            family: target.family,
            data: data,
            coverage: coverage,
            options: fitOptions,
            generated: generatedGeometry,
            radiusMarginMm: margin,
            inputWarnings: inputWarnings
        )
        return context.run()
    }

    /// 只做点数/坐标合法性检查（会话保存前也可以调用）。
    public static func validateTraces(
        _ trace: CalibrationCrossTrace,
        physicalOuterRadiusMm: Double = 60
    ) throws {
        guard trace.armIndex == 0 else {
            throw DiscError.invalidGeometry("曲线编号无效。")
        }
        guard trace.points.count <= 20_000 else {
            throw DiscError.invalidGeometry("曲线点数量超出限制。")
        }
        for point in trace.points {
            guard point.xMm.isFinite, point.yMm.isFinite,
                  abs(point.xMm) <= 1000, abs(point.yMm) <= 1000,
                  point.xMm * point.xMm + point.yMm * point.yMm >= 0.01 else {
                throw DiscError.invalidGeometry("曲线点坐标无效，请使用矫正后以盘心为原点的坐标。")
            }
            guard point.radiusMm <= physicalOuterRadiusMm + 0.01 else {
                throw DiscError.invalidGeometry("曲线点超出盘面范围，请检查照片矫正。")
            }
        }
    }

    private static func validate(points: [CalibrationPoint], session: CalibrationSession) throws {
        let physicalOuter = session.photo?.physicalOuterRadiusMm
            ?? CalibrationDiscSize.standard12cm.physicalOuterRadiusMm
        try validateTraces(
            CalibrationCrossTrace(armIndex: 0, points: points),
            physicalOuterRadiusMm: physicalOuter
        )
    }

    // MARK: - 数据结构

    private struct Datum {
        let trace: Int
        let radius: Double
        let angle: Double
        let angularScale: Double
        let weight: Double
    }

    private struct Solution {
        let inner: Double
        let outer: Double
        let rotation: Double
        let cost: Double
        let rms: Double
        let residuals: [Double]

        static func invalid(inner: Double, outer: Double) -> Solution {
            Solution(inner: inner, outer: outer, rotation: 0, cost: .infinity, rms: .infinity, residuals: [])
        }
    }

    private struct SolveOutcome {
        let result: CalibrationFitResult
        let residuals: [Double]
        let boundaryLimited: Bool
    }

    private struct CubicSolution {
        let parameters: CalibrationParameters
        let rotation: Double
        let cost: Double
        let rms: Double
        let residuals: [Double]

        static func invalid(_ parameters: CalibrationParameters) -> CubicSolution {
            CubicSolution(parameters: parameters, rotation: 0, cost: .infinity, rms: .infinity, residuals: [])
        }
    }

    // MARK: - 数据准备

    private static func prepare(
        points: [CalibrationPoint],
        band: Double,
        warnings: inout [String]
    ) -> (data: [Datum], failure: String?) {
        var deduplicated: [CalibrationPoint] = []
        for point in points {
            if let last = deduplicated.last, last == point { continue }
            deduplicated.append(point)
        }
        guard deduplicated.count >= 2 else {
            return ([], nil)
        }
        let count = deduplicated.count
        var radii = [Double](repeating: 0, count: count)
        var angles = [Double](repeating: 0, count: count)
        for index in 0..<count {
            radii[index] = deduplicated[index].radiusMm
            let angle = deduplicated[index].angleRadians
            if index == 0 {
                // 单臂：起始臂角按 0 号臂（-π/2）处理，整体转角作为独立量拟合。
                angles[index] = angle + .pi / 2
            } else {
                if radii[index] < radii[index - 1] - max(0.1, band * 0.005) {
                    return ([], "曲线出现明显向内回退，请按内到外的顺序沿同一条线标点。")
                }
                let change = normalize(angle - deduplicated[index - 1].angleRadians)
                if abs(change) > .pi * 0.995 {
                    return ([], "相邻曲线点转角接近半圈，无法判断是否漏掉整圈；请在这两点之间沿实际曲线补点。")
                }
                if abs(change) > .pi * 0.9, !warnings.contains(nearHalfTurnWarning) {
                    warnings.append(nearHalfTurnWarning)
                }
                angles[index] = angles[index - 1] + change
            }
        }
        if radii[count - 1] - radii[0] < band * 0.02 {
            return ([], nil)
        }
        if count > 1024, !warnings.contains("曲线点较多，拟合使用均匀抽取的点；完整顺序仍用于角度展开。") {
            warnings.append("曲线点较多，拟合使用均匀抽取的点；完整顺序仍用于角度展开。")
        }

        let kept = min(count, 1024)
        var data: [Datum] = []
        data.reserveCapacity(kept)
        for slot in 0..<kept {
            let index = Int((Double(slot) * Double(count - 1) / Double(kept - 1)).rounded())
            let before = max(0, index - 2)
            let after = min(count - 1, index + 2)
            var meanRadius = 0.0
            var meanAngle = 0.0
            for neighbor in before...after {
                meanRadius += radii[neighbor]
                meanAngle += angles[neighbor]
            }
            let neighbors = Double(after - before + 1)
            meanRadius /= neighbors
            meanAngle /= neighbors
            var covariance = 0.0
            var variance = 0.0
            for neighbor in before...after {
                covariance += (radii[neighbor] - meanRadius) * (angles[neighbor] - meanAngle)
                variance += (radii[neighbor] - meanRadius) * (radii[neighbor] - meanRadius)
            }
            let slope = covariance / max(variance, 1e-12)
            let angularScale = radii[index] / (1 + radii[index] * radii[index] * slope * slope).squareRoot()
            let previous = slot == 0 ? 0
                : Int((Double(slot - 1) * Double(count - 1) / Double(kept - 1)).rounded())
            let next = slot == kept - 1 ? count - 1
                : Int((Double(slot + 1) * Double(count - 1) / Double(kept - 1)).rounded())
            let weight = max(1e-8, radii[next] - radii[previous]) / (radii[count - 1] - radii[0])
            data.append(Datum(
                trace: 0,
                radius: radii[index],
                angle: angles[index],
                angularScale: angularScale.isFinite && angularScale > 0 ? angularScale : 1,
                weight: weight.isFinite && weight > 0 ? weight : 1e-8
            ))
        }
        return (data, nil)
    }

    // MARK: - 求解上下文

    private final class SolverContext {
        let target: CalibrationParameters
        let center: CalibrationParameters
        let family: DiscFamily
        let data: [Datum]
        let coverage: Double
        let options: CalibrationFitOptions
        let generated: CalibrationTrackGeometry
        let radiusMarginMm: Double
        let inputWarnings: [String]
        let traces: Int

        private var geometryCache: [[Double]: CalibrationTrackGeometry?] = [:]

        init(
            target: CalibrationParameters,
            center: CalibrationParameters,
            family: DiscFamily,
            data: [Datum],
            coverage: Double,
            options: CalibrationFitOptions,
            generated: CalibrationTrackGeometry,
            radiusMarginMm: Double,
            inputWarnings: [String]
        ) {
            self.target = target
            self.center = center
            self.family = family
            self.data = data
            self.coverage = coverage
            self.options = options
            self.generated = generated
            self.radiusMarginMm = radiusMarginMm
            self.inputWarnings = inputWarnings
            self.traces = (data.map(\.trace).max() ?? 0) + 1
        }

        // MARK: 自动范围

        func run() -> CalibrationFitResult {
            var usedRange = options.searchRangeMm
            var outcome = solve(range: usedRange, delta: options.huberDeltaMm)
            var warnings = outcome.result.warnings

            if options.autoRange {
                while usedRange < (CalibrationFitOptions.autoRangeSteps.last ?? 0.5) - 1e-9,
                      !outcome.result.succeeded || outcome.boundaryLimited {
                    guard let next = CalibrationFitOptions.autoRangeSteps.first(where: { $0 > usedRange + 1e-9 }) else {
                        break
                    }
                    let previous = usedRange
                    usedRange = next
                    warnings.append(
                        "最佳结果靠近搜索边界（±\(Self.number(previous)) mm），已自动扩大到 ±\(Self.number(next)) mm 重算。"
                    )
                    outcome = solve(range: usedRange, delta: options.huberDeltaMm)
                    warnings = outcome.result.warnings.mergingMissing(from: warnings)
                }
            }

            if !outcome.result.succeeded {
                return outcome.result
            }
            if let best = outcome.result.best, !best.isApplicable {
                warnings.append(outcome.result.rejectionReason ?? "残差过大，候选不可应用。")
            }
            if !outcome.result.warnings.contains(radiusBoundsWarning) {
                warnings.append(radiusBoundsWarning)
            }
            var result = outcome.result
            result.warnings = deduplicate(warnings)
            result.searchRangeMm = (-usedRange, usedRange)
            return result
        }

        // MARK: 一次有界搜索

        func solve(range: Double, delta: Double) -> SolveOutcome {
            var warnings = inputWarnings
            let lowerInner = max(0.1, center.innerRadiusMm - range)
            let upperInner = center.innerRadiusMm + range
            let lowerOuter = max(lowerInner + 0.1, center.outerRadiusMm - range)
            let upperOuter = center.outerRadiusMm + range

            func evaluate(_ inner: Double, _ outer: Double) -> Solution {
                guard inner >= lowerInner, inner <= upperInner,
                      outer >= lowerOuter, outer <= upperOuter,
                      outer > inner,
                      center.trackLengthMm > outer - inner else {
                    return .invalid(inner: inner, outer: outer)
                }
                guard let actual = geometry(inner: inner, outer: outer) else {
                    return .invalid(inner: inner, outer: outer)
                }
                let candidate = center.replacingRadii(inner: inner, outer: outer)
                let model = CalibrationCrossModel(
                    generated: generated,
                    actual: actual,
                    family: family,
                    identical: candidate == target
                )
                var angles = [Double](repeating: 0, count: data.count)
                var mean = 0.0
                var meanWeight = 0.0
                for (index, point) in data.enumerated() {
                    guard let predicted = model.sample(atRadius: point.radius) else {
                        return .invalid(inner: inner, outer: outer)
                    }
                    angles[index] = point.angle - predicted.phase
                    let weight = point.weight * point.angularScale * point.angularScale
                    mean += weight * angles[index]
                    meanWeight += weight
                }
                guard meanWeight > 0, meanWeight.isFinite else {
                    return .invalid(inner: inner, outer: outer)
                }
                mean /= meanWeight
                // 整体转角作为独立量：先由圆均值定初值，再把整条 trace 展开到该分支。
                var rotation = atan2(sin(mean), cos(mean))
                for index in angles.indices {
                    angles[index] += 2 * .pi * ((rotation - mean) / (2 * .pi)).rounded()
                }
                for _ in 0..<10 {
                    var sum = 0.0
                    var weightSum = 0.0
                    for (index, point) in data.enumerated() {
                        let error = abs((angles[index] - rotation) * point.angularScale)
                        let weight = point.weight * point.angularScale * point.angularScale
                            * (error <= delta ? 1 : delta / error)
                        sum += weight * angles[index]
                        weightSum += weight
                    }
                    guard weightSum > 0 else { break }
                    let updated = sum / weightSum
                    if abs(updated - rotation) < 1e-12 {
                        rotation = updated
                        break
                    }
                    rotation = updated
                }
                var residuals = [Double](repeating: 0, count: data.count)
                var cost = 0.0
                var squared = 0.0
                var weights = 0.0
                for (index, point) in data.enumerated() {
                    let residual = (angles[index] - rotation) * point.angularScale
                    residuals[index] = residual
                    let error = abs(residual)
                    cost += point.weight * (error <= delta ? 0.5 * error * error : delta * (error - delta / 2))
                    squared += point.weight * residual * residual
                    weights += point.weight
                }
                guard weights > 0 else { return .invalid(inner: inner, outer: outer) }
                return Solution(
                    inner: inner,
                    outer: outer,
                    rotation: rotation,
                    cost: cost / weights,
                    rms: (squared / weights).squareRoot(),
                    residuals: residuals
                )
            }

            func refine(_ initial: Solution) -> Solution {
                var current = initial
                var damping = 1e-4
                for _ in 0..<80 {
                    guard let derivatives = jacobian(current, evaluate: evaluate) else { break }
                    var a = 0.0
                    var b = 0.0
                    var c = 0.0
                    var x = 0.0
                    var y = 0.0
                    for index in data.indices {
                        let error = abs(current.residuals[index])
                        let weight = data[index].weight * (error <= delta ? 1 : delta / error)
                        a += weight * derivatives.first[index] * derivatives.first[index]
                        b += weight * derivatives.first[index] * derivatives.second[index]
                        c += weight * derivatives.second[index] * derivatives.second[index]
                        x -= weight * derivatives.first[index] * current.residuals[index]
                        y -= weight * derivatives.second[index] * current.residuals[index]
                    }
                    a *= 1 + damping
                    c *= 1 + damping
                    let determinant = a * c - b * b
                    guard determinant.isFinite, determinant > 1e-20 else { break }
                    let innerStep = (x * c - y * b) / determinant
                    let outerStep = (y * a - x * b) / determinant
                    let proposed = evaluate(current.inner + innerStep, current.outer + outerStep)
                    if proposed.cost < current.cost {
                        let improvement = current.cost - proposed.cost
                        current = proposed
                        damping = max(1e-10, damping / 3)
                        if improvement < 1e-15 || max(abs(innerStep), abs(outerStep)) < 1e-10 { break }
                    } else {
                        damping *= 8
                        if damping > 1e12 { break }
                    }
                }
                return current
            }

            // 解析形状初值：先剥离非恒定相位形状，给搜索一个好的起点。
            let shapeSeeds = estimateShapeSeeds().map {
                evaluate(
                    min(max($0.inner, lowerInner), upperInner),
                    min(max($0.outer, lowerOuter), upperOuter)
                )
            }.filter { $0.cost.isFinite }

            let gridSize = range <= 0.05 ? 9 : 17
            var seeds: [Solution] = [evaluate(center.innerRadiusMm, center.outerRadiusMm)]
            for row in 0..<gridSize {
                for column in 0..<gridSize {
                    seeds.append(evaluate(
                        lowerInner + (upperInner - lowerInner) * Double(row) / Double(gridSize - 1),
                        lowerOuter + (upperOuter - lowerOuter) * Double(column) / Double(gridSize - 1)
                    ))
                }
            }
            let ranked = seeds.filter { $0.cost.isFinite }.sorted { $0.cost < $1.cost }.prefix(16)

            var solutions: [Solution] = []
            for seed in shapeSeeds + ranked {
                let result = refine(seed)
                if let duplicate = solutions.firstIndex(where: {
                    abs($0.inner - result.inner) < 1e-6 && abs($0.outer - result.outer) < 1e-6
                }) {
                    if result.cost < solutions[duplicate].cost { solutions[duplicate] = result }
                } else {
                    solutions.append(result)
                }
            }
            solutions.sort { $0.cost < $1.cost }
            guard let best = solutions.first else {
                return SolveOutcome(
                    result: .failed([
                        "搜索范围内没有能覆盖全部观测点的有效正半径曲线延拓，请检查照片尺度、盘心或参数范围。",
                    ]),
                    residuals: [],
                    boundaryLimited: false
                )
            }
            let boundaryLimited = onBoundary(
                best,
                lowerInner: lowerInner,
                upperInner: upperInner,
                lowerOuter: lowerOuter,
                upperOuter: upperOuter,
                range: range
            )

            if family == .bluRay {
                let bestParameters = center.replacingRadii(inner: best.inner, outer: best.outer)
                if let actual = geometry(inner: best.inner, outer: best.outer) {
                    let model = CalibrationCrossModel(
                        generated: generated,
                        actual: actual,
                        family: family,
                        identical: bestParameters == target
                    )
                    let drawingInner = target.drawingInnerRadiusMm
                    let drawingOuter = target.drawingOuterRadiusMm
                    let outside = data.contains { point in
                        guard let predicted = model.sample(atRadius: point.radius) else { return false }
                        return predicted.sourceRadius < drawingInner - 1e-8
                            || predicted.sourceRadius > drawingOuter + 1e-8
                    }
                    if outside {
                        warnings.append(
                            "部分描点在候选模型下超出原图案环带，已按连续曲线保留；请复核照片尺度、盘心及端点是否沿同一条可见曲线。"
                        )
                    }
                }
            }
            if coverage < 0.6 {
                warnings.append("曲线覆盖的内外范围偏窄，参数可能互相补偿；请补充更靠内、外的点。")
            }
            if best.rms > delta * 2 {
                warnings.append("曲线偏差较大，请检查照片矫正、点位和是否始终沿同一条线标点。")
            }
            if boundaryLimited {
                warnings.append("最佳结果靠近搜索边界，建议扩大搜索范围并补充曲线点复核。")
            }
            if parameterCorrelation(best, evaluate: evaluate) > 0.998 {
                warnings.append("当前曲线对两个半径的约束较相似，暂不能仅凭低残差判断参数唯一；请扩大径向覆盖并检查点位精度。")
            }
            if solutions.dropFirst().contains(where: { solution in
                solution.cost <= best.cost + max(0.005, best.cost * 0.25)
                    && (abs(solution.inner - best.inner) > 0.0002
                        || abs(solution.outer - best.outer) > 0.0002)
            }) {
                warnings.append("存在形状接近的参数候选，请对照整条曲线后再应用。")
            }
            if range > 0.05 {
                warnings.append("宽范围只进行了有限多起点搜索，候选列表不代表穷尽所有可能参数。")
            }

            var candidates: [CalibrationFitCandidate] = []
            for solution in solutions.prefix(options.maxCandidates) {
                let stats = residualStats(solution.residuals, delta: delta)
                candidates.append(CalibrationFitCandidate(
                    innerRadiusMm: solution.inner,
                    outerRadiusMm: solution.outer,
                    rotationRadians: CalibrationCrossFitter.normalize(solution.rotation),
                    pitchLinear: center.pitchLinear,
                    pitchQuadratic: center.pitchQuadratic,
                    pitchCubic: center.pitchCubic,
                    rmsErrorMm: solution.rms,
                    maxErrorMm: stats.maximum,
                    outlierCount: stats.outliers,
                    robustCost: solution.cost
                ))
            }
            guard let firstCandidate = candidates.first else {
                return SolveOutcome(
                    result: .failed(["搜索范围内没有可用的参数候选。"]),
                    residuals: [],
                    boundaryLimited: boundaryLimited
                )
            }
            if family == .dvd, options.fitDvdPitch {
                return fitCubic(
                    baseline: candidates,
                    coverage: coverage,
                    warnings: warnings,
                    baselineResiduals: best.residuals,
                    delta: delta,
                    boundaryLimited: boundaryLimited,
                    range: range
                )
            }
            let result = CalibrationFitResult(
                succeeded: true,
                candidates: candidates,
                best: firstCandidate,
                warnings: warnings,
                searchRangeMm: nil,
                boundaryLimited: boundaryLimited
            )
            return SolveOutcome(result: result, residuals: best.residuals, boundaryLimited: boundaryLimited)
        }

        // MARK: 几何缓存

        private func geometry(inner: Double, outer: Double) -> CalibrationTrackGeometry? {
            let key = [inner, outer, center.pitchLinear, center.pitchQuadratic, center.pitchCubic]
            if let cached = geometryCache[key] { return cached }
            let parameters = center.replacingRadii(inner: inner, outer: outer)
            let geometry = try? CalibrationTrackGeometry(
                parameters: parameters,
                radiusMarginMm: radiusMarginMm
            )
            geometryCache[key] = geometry
            return geometry
        }

        private func geometry(parameters: CalibrationParameters) -> CalibrationTrackGeometry? {
            let key = [
                parameters.innerRadiusMm, parameters.outerRadiusMm,
                parameters.pitchLinear, parameters.pitchQuadratic, parameters.pitchCubic,
            ]
            if let cached = geometryCache[key] { return cached }
            let geometry = try? CalibrationTrackGeometry(
                parameters: parameters,
                radiusMarginMm: radiusMarginMm
            )
            geometryCache[key] = geometry
            return geometry
        }

        // MARK: 数值辅助

        private func jacobian(
            _ current: Solution,
            evaluate: (Double, Double) -> Solution
        ) -> (first: [Double], second: [Double])? {
            let step = 1e-6
            var shiftedInner = evaluate(current.inner + step, current.outer)
            var innerStep = step
            if !shiftedInner.cost.isFinite {
                innerStep = -step
                shiftedInner = evaluate(current.inner - step, current.outer)
            }
            var shiftedOuter = evaluate(current.inner, current.outer + step)
            var outerStep = step
            if !shiftedOuter.cost.isFinite {
                outerStep = -step
                shiftedOuter = evaluate(current.inner, current.outer - step)
            }
            guard shiftedInner.cost.isFinite, shiftedOuter.cost.isFinite,
                  shiftedInner.residuals.count == current.residuals.count,
                  shiftedOuter.residuals.count == current.residuals.count else { return nil }
            var first = [Double](repeating: 0, count: current.residuals.count)
            var second = [Double](repeating: 0, count: current.residuals.count)
            for index in current.residuals.indices {
                first[index] = (shiftedInner.residuals[index] - current.residuals[index]) / innerStep
                second[index] = (shiftedOuter.residuals[index] - current.residuals[index]) / outerStep
            }
            return (first, second)
        }

        private func parameterCorrelation(
            _ solution: Solution,
            evaluate: (Double, Double) -> Solution
        ) -> Double {
            guard let jacobian = jacobian(solution, evaluate: evaluate) else { return 1 }
            var a = 0.0
            var b = 0.0
            var c = 0.0
            for index in data.indices {
                a += data[index].weight * jacobian.first[index] * jacobian.first[index]
                b += data[index].weight * jacobian.first[index] * jacobian.second[index]
                c += data[index].weight * jacobian.second[index] * jacobian.second[index]
            }
            return abs(b) / max(1e-30, a * c).squareRoot()
        }

        private func residualStats(_ residuals: [Double], delta: Double) -> (maximum: Double, outliers: Int) {
            guard !residuals.isEmpty else { return (0, 0) }
            let threshold = max(0.05, delta * 3)
            var maximum = 0.0
            var outliers = 0
            for residual in residuals {
                let error = abs(residual)
                maximum = max(maximum, error)
                if error > threshold { outliers += 1 }
            }
            return (maximum, outliers)
        }

        private func onBoundary(
            _ solution: Solution,
            lowerInner: Double,
            upperInner: Double,
            lowerOuter: Double,
            upperOuter: Double,
            range: Double
        ) -> Bool {
            min(solution.inner - lowerInner, upperInner - solution.inner) < range * 0.005
                || min(solution.outer - lowerOuter, upperOuter - solution.outer) < range * 0.005
        }

        // MARK: 解析形状初值（上游 EstimateShapeSeeds）

        private func estimateShapeSeeds() -> [(inner: Double, outer: Double)] {
            var radiusSum = 0.0
            for point in data { radiusSum += point.weight * point.angularScale * point.angularScale * point.radius }
            var totalWeight = 0.0
            for point in data { totalWeight += point.weight * point.angularScale * point.angularScale }
            guard totalWeight > 0 else { return [] }
            let radiusScale = radiusSum / totalWeight
            guard radiusScale.isFinite, radiusScale > 0 else { return [] }

            var meanRadius = 0.0
            var meanInverse = 0.0
            var meanAngle = 0.0
            for point in data {
                let weight = point.weight * point.angularScale * point.angularScale
                meanRadius += weight * point.radius
                meanInverse += weight / point.radius
                meanAngle += weight * point.angle
            }
            meanRadius /= totalWeight
            meanInverse /= totalWeight
            meanAngle /= totalWeight

            var uu = 0.0
            var uv = 0.0
            var vv = 0.0
            var uy = 0.0
            for point in data {
                let weight = point.weight * point.angularScale * point.angularScale
                let u = (point.radius - meanRadius) / radiusScale
                let v = (1 / point.radius - meanInverse) * radiusScale
                let y = point.angle - meanAngle
                uu += weight * u * u
                uv += weight * u * v
                vv += weight * v * v
                uy += weight * u * y
            }
            guard uu.isFinite, vv.isFinite, uu > 0, vv > 0 else { return [] }
            let projection = uv / uu
            var perpendicularSquared = 0.0
            var perpendicularY = 0.0
            for point in data {
                let weight = point.weight * point.angularScale * point.angularScale
                let u = (point.radius - meanRadius) / radiusScale
                let v = (1 / point.radius - meanInverse) * radiusScale - projection * u
                perpendicularSquared += weight * v * v
                perpendicularY += weight * v * (point.angle - meanAngle)
            }
            guard perpendicularSquared.isFinite, perpendicularSquared > vv * 1e-14 else { return [] }
            let inverseCoefficient = perpendicularY / perpendicularSquared
            let alpha = (uy - inverseCoefficient * uv) / (uu * radiusScale)
            let beta = inverseCoefficient * radiusScale
            let bg = (target.outerRadiusMm - target.innerRadiusMm)
                * (target.outerRadiusMm + target.innerRadiusMm) / (2 * target.trackLengthMm)
            let eta = center.trackLengthMm / target.trackLengthMm
            let discriminant = 1 + 4 * eta * alpha * bg
            guard alpha.isFinite, beta.isFinite, discriminant.isFinite, discriminant >= 0 else { return [] }
            let q = (1 + discriminant.squareRoot()) / 2
            var seeds: [(inner: Double, outer: Double)] = []
            for candidate in [q / eta, -alpha * bg / q] {
                let z = candidate
                guard z.isFinite, z > 0 else { continue }
                let k = z * z
                let d = -2 * z * bg * beta
                let innerSquared = (target.innerRadiusMm * target.innerRadiusMm - d) / k
                let outerSquared = (target.outerRadiusMm * target.outerRadiusMm - d) / k
                guard innerSquared.isFinite, outerSquared.isFinite,
                      innerSquared > 0, outerSquared > innerSquared else { continue }
                seeds.append((innerSquared.squareRoot(), outerSquared.squareRoot()))
            }
            return seeds
        }

        // MARK: 三次轨距

        private func fitCubic(
            baseline: [CalibrationFitCandidate],
            coverage: Double,
            warnings: [String],
            baselineResiduals: [Double],
            delta: Double,
            boundaryLimited: Bool,
            range: Double
        ) -> SolveOutcome {
            var warnings = warnings
            func baselineOutcome() -> SolveOutcome {
                let result = CalibrationFitResult(
                    succeeded: true,
                    candidates: baseline,
                    best: baseline.first,
                    warnings: warnings,
                    searchRangeMm: nil,
                    boundaryLimited: boundaryLimited
                )
                return SolveOutcome(result: result, residuals: baselineResiduals, boundaryLimited: boundaryLimited)
            }
            // 三次形状项 + 两个半径 + 转角需要远多于恒定轨距的支持。
            let radialLevels = Set(data.map { ($0.radius * 10_000).rounded() }).count
            if radialLevels < 12 || coverage < 0.6 {
                warnings.append("三次轨距拟合需要至少 12 个不同半径的点且覆盖至少 60% 绘图区；本次保持轨距系数，只拟合内外半径。")
                return baselineOutcome()
            }
            // 已经低到微米级的曲线不再硬造系数，避免把数值噪声当物理量。
            if let first = baseline.first, first.rmsErrorMm < 1e-6 {
                return baselineOutcome()
            }

            let lowerInner = max(0.1, center.innerRadiusMm - range)
            let upperInner = center.innerRadiusMm + range
            let lowerOuter = max(lowerInner + 0.1, center.outerRadiusMm - range)
            let upperOuter = center.outerRadiusMm + range
            let coefficientRange = options.pitchCoefficientRange

            func evaluate(_ parameters: CalibrationParameters) -> CubicSolution {
                guard abs(parameters.innerRadiusMm - center.innerRadiusMm) <= range,
                      abs(parameters.outerRadiusMm - center.outerRadiusMm) <= range,
                      abs(parameters.pitchLinear - center.pitchLinear) <= coefficientRange,
                      abs(parameters.pitchQuadratic - center.pitchQuadratic) <= coefficientRange,
                      abs(parameters.pitchCubic - center.pitchCubic) <= coefficientRange,
                      parameters.outerRadiusMm > parameters.innerRadiusMm,
                      center.trackLengthMm > parameters.outerRadiusMm - parameters.innerRadiusMm else {
                    return .invalid(parameters)
                }
                guard let actual = geometry(parameters: parameters) else { return .invalid(parameters) }
                let model = CalibrationCrossModel(
                    generated: generated,
                    actual: actual,
                    family: family,
                    identical: parameters == target
                )
                var angles = [Double](repeating: 0, count: data.count)
                var mean = 0.0
                var meanWeight = 0.0
                for (index, point) in data.enumerated() {
                    guard let predicted = model.sample(atRadius: point.radius) else {
                        return .invalid(parameters)
                    }
                    angles[index] = point.angle - predicted.phase
                    let weight = point.weight * point.angularScale * point.angularScale
                    mean += weight * angles[index]
                    meanWeight += weight
                }
                guard meanWeight > 0, meanWeight.isFinite else { return .invalid(parameters) }
                mean /= meanWeight
                var rotation = atan2(sin(mean), cos(mean))
                for index in angles.indices {
                    angles[index] += 2 * .pi * ((rotation - mean) / (2 * .pi)).rounded()
                }
                for _ in 0..<12 {
                    var sum = 0.0
                    var weightSum = 0.0
                    for (index, point) in data.enumerated() {
                        let error = abs((angles[index] - rotation) * point.angularScale)
                        let weight = point.weight * point.angularScale * point.angularScale
                            * (error <= delta ? 1 : delta / error)
                        sum += weight * angles[index]
                        weightSum += weight
                    }
                    guard weightSum > 0 else { break }
                    let updated = sum / weightSum
                    if abs(updated - rotation) < 1e-12 {
                        rotation = updated
                        break
                    }
                    rotation = updated
                }
                var residuals = [Double](repeating: 0, count: data.count)
                var cost = 0.0
                var squared = 0.0
                var weightSum = 0.0
                for (index, point) in data.enumerated() {
                    let residual = (angles[index] - rotation) * point.angularScale
                    residuals[index] = residual
                    let error = abs(residual)
                    cost += point.weight * (error <= delta ? 0.5 * error * error : delta * (error - delta / 2))
                    squared += point.weight * residual * residual
                    weightSum += point.weight
                }
                guard weightSum > 0 else { return .invalid(parameters) }
                return CubicSolution(
                    parameters: parameters,
                    rotation: rotation,
                    cost: cost / weightSum,
                    rms: (squared / weightSum).squareRoot(),
                    residuals: residuals
                )
            }

            func refine(_ initial: CubicSolution) -> CubicSolution {
                var current = initial
                var damping = 1e-5
                var iterations = 0
                while iterations < 60, current.cost.isFinite {
                    iterations += 1
                    guard let jacobian = cubicJacobian(current, evaluate: evaluate) else { break }
                    var matrix = [[Double]](repeating: [Double](repeating: 0, count: 5), count: 5)
                    var rhs = [Double](repeating: 0, count: 5)
                    var scales = [Double](repeating: 0, count: 5)
                    for index in data.indices {
                        let error = abs(current.residuals[index])
                        let weight = data[index].weight * (error <= delta ? 1 : delta / error)
                        for a in 0..<5 {
                            rhs[a] -= weight * jacobian[a][index] * current.residuals[index]
                            for b in 0...a {
                                matrix[a][b] += weight * jacobian[a][index] * jacobian[b][index]
                            }
                        }
                    }
                    for a in 0..<5 { scales[a] = max(matrix[a][a], 1e-30).squareRoot() }
                    for a in 0..<5 {
                        rhs[a] /= scales[a]
                        for b in 0...a {
                            let value = matrix[a][b] / (scales[a] * scales[b])
                            matrix[a][b] = value
                            matrix[b][a] = value
                        }
                        matrix[a][a] += damping
                    }
                    guard Self.solveLinearSystem(&matrix, &rhs, size: 5) else { break }
                    let vector = Self.cubicVector(current.parameters)
                    var proposed = current
                    for backtrack in 0..<12 {
                        let fraction = pow(0.5, Double(backtrack))
                        var next = vector
                        for index in 0..<5 { next[index] += fraction * rhs[index] / scales[index] }
                        proposed = evaluate(Self.cubicParameters(from: current.parameters, vector: next))
                        if proposed.cost < current.cost { break }
                    }
                    if proposed.cost < current.cost {
                        let improvement = current.cost - proposed.cost
                        current = proposed
                        damping = max(1e-12, damping / 3)
                        if current.rms < 1e-7 || improvement < 1e-17 { break }
                    } else {
                        damping *= 10
                        if damping > 1e10 { break }
                    }
                }
                return current
            }

            var starts: [CalibrationParameters] = []
            for candidate in baseline.prefix(3) {
                let parameters = center
                    .replacingRadii(inner: candidate.innerRadiusMm, outer: candidate.outerRadiusMm)
                    .replacingPitch(
                        linear: candidate.pitchLinear,
                        quadratic: candidate.pitchQuadratic,
                        cubic: candidate.pitchCubic
                    )
                if !starts.contains(where: { Self.cubicVector($0) == Self.cubicVector(parameters) }) {
                    starts.append(parameters)
                }
            }
            if !starts.contains(where: { Self.cubicVector($0) == Self.cubicVector(center) }) {
                starts.append(center)
            }

            var solutions: [CubicSolution] = []
            for start in starts {
                let result = refine(evaluate(start))
                guard result.cost.isFinite else { continue }
                if let duplicate = solutions.firstIndex(where: { solution in
                    let lhs = Self.cubicVector(solution.parameters)
                    let rhs = Self.cubicVector(result.parameters)
                    return zip(lhs, rhs).enumerated().allSatisfy { index, pair in
                        abs(pair.0 - pair.1) < (index < 2 ? 1e-6 : 1e-8)
                    }
                }) {
                    if result.cost < solutions[duplicate].cost { solutions[duplicate] = result }
                } else {
                    solutions.append(result)
                }
            }
            solutions.sort { $0.cost < $1.cost }
            guard let best = solutions.first,
                  let baselineFirst = baseline.first,
                  best.cost < baselineFirst.robustCost * 0.995 else {
                warnings.append("三次轨距没有带来稳定改善，保留原轨距系数；可增加内、中、外圈点位后重试。")
                return baselineOutcome()
            }
            guard let bestJacobian = cubicJacobian(best, evaluate: evaluate),
                  Self.jacobianIndependence(bestJacobian, data: data) >= 1e-7 else {
                warnings.append("当前点位无法稳定区分三个轨距系数与内外半径，本次保留原轨距系数；请扩大径向覆盖并提高点位精度。")
                return baselineOutcome()
            }
            warnings.removeAll {
                $0.hasPrefix("曲线偏差较大") || $0.hasPrefix("最佳结果靠近")
                    || $0.hasPrefix("当前曲线对两个半径") || $0.hasPrefix("存在形状接近")
            }
            if best.rms > delta * 2 {
                warnings.append("曲线偏差较大，请检查照片矫正、点位和是否始终沿同一条线标点。")
            }
            if max(abs(best.parameters.innerRadiusMm - center.innerRadiusMm),
                   abs(best.parameters.outerRadiusMm - center.outerRadiusMm)) > range * 0.995 {
                warnings.append("最佳结果靠近搜索边界，建议扩大搜索范围并补充曲线点复核。")
            }
            warnings.append("已拟合 DVD 三次轨距；三个形状系数与内外半径可能互相补偿，低残差不表示参数唯一，应用前请核对整条预测曲线。")
            if max(abs(best.parameters.pitchLinear - center.pitchLinear),
                   abs(best.parameters.pitchQuadratic - center.pitchQuadratic),
                   abs(best.parameters.pitchCubic - center.pitchCubic)) > coefficientRange * 0.995 {
                warnings.append("轨距系数接近搜索边界，请复核点位，必要时扩大系数搜索范围。")
            }
            var candidates: [CalibrationFitCandidate] = []
            for solution in solutions.prefix(options.maxCandidates) {
                let stats = residualStats(solution.residuals, delta: delta)
                candidates.append(CalibrationFitCandidate(
                    innerRadiusMm: solution.parameters.innerRadiusMm,
                    outerRadiusMm: solution.parameters.outerRadiusMm,
                    rotationRadians: CalibrationCrossFitter.normalize(solution.rotation),
                    pitchLinear: solution.parameters.pitchLinear,
                    pitchQuadratic: solution.parameters.pitchQuadratic,
                    pitchCubic: solution.parameters.pitchCubic,
                    rmsErrorMm: solution.rms,
                    maxErrorMm: stats.maximum,
                    outlierCount: stats.outliers,
                    robustCost: solution.cost
                ))
            }
            guard let firstCandidate = candidates.first else {
                warnings.append("三次轨距没有产生可用候选，保留原轨距系数。")
                return baselineOutcome()
            }
            let cubicBoundary = min(best.parameters.innerRadiusMm - lowerInner,
                                    upperInner - best.parameters.innerRadiusMm) < range * 0.005
                || min(best.parameters.outerRadiusMm - lowerOuter,
                       upperOuter - best.parameters.outerRadiusMm) < range * 0.005
            let result = CalibrationFitResult(
                succeeded: true,
                candidates: candidates,
                best: firstCandidate,
                warnings: warnings,
                searchRangeMm: nil,
                boundaryLimited: cubicBoundary
            )
            return SolveOutcome(result: result, residuals: best.residuals, boundaryLimited: cubicBoundary)
        }

        private func cubicJacobian(
            _ current: CubicSolution,
            evaluate: (CalibrationParameters) -> CubicSolution
        ) -> [[Double]]? {
            var jacobian: [[Double]] = []
            let vector = Self.cubicVector(current.parameters)
            for column in 0..<5 {
                let step = column < 2 ? 2e-6 : 2e-7
                var plus = vector
                var minus = vector
                plus[column] += step
                minus[column] -= step
                var forward = evaluate(Self.cubicParameters(from: current.parameters, vector: plus))
                var backward = evaluate(Self.cubicParameters(from: current.parameters, vector: minus))
                var span = 2 * step
                if !forward.cost.isFinite && !backward.cost.isFinite { return nil }
                if !forward.cost.isFinite { forward = current; span -= step }
                if !backward.cost.isFinite { backward = current; span -= step }
                guard span > 0,
                      forward.residuals.count == current.residuals.count,
                      backward.residuals.count == current.residuals.count else { return nil }
                var columnValues = [Double](repeating: 0, count: current.residuals.count)
                for index in current.residuals.indices {
                    columnValues[index] = (forward.residuals[index] - backward.residuals[index]) / span
                }
                jacobian.append(columnValues)
            }
            return jacobian
        }

        private static func cubicVector(_ parameters: CalibrationParameters) -> [Double] {
            [
                parameters.innerRadiusMm,
                parameters.outerRadiusMm,
                parameters.pitchLinear,
                parameters.pitchQuadratic,
                parameters.pitchCubic,
            ]
        }

        private static func cubicParameters(
            from parameters: CalibrationParameters,
            vector: [Double]
        ) -> CalibrationParameters {
            parameters
                .replacingRadii(inner: vector[0], outer: vector[1])
                .replacingPitch(linear: vector[2], quadratic: vector[3], cubic: vector[4])
        }

        /// 逐列正交化后的最小独立度（挡住几乎共线的第五个参数）。
        private static func jacobianIndependence(_ jacobian: [[Double]], data: [Datum]) -> Double {
            var basis: [[Double]] = []
            var independence = 1.0
            for column in jacobian {
                var values = column.enumerated().map { index, value in
                    value * data[index].weight.squareRoot()
                }
                let norm = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
                guard norm.isFinite, norm > 0 else { return 0 }
                values = values.map { $0 / norm }
                for _ in 0..<2 {
                    for previous in basis {
                        let projection = zip(values, previous).reduce(0) { $0 + $1.0 * $1.1 }
                        for index in values.indices { values[index] -= projection * previous[index] }
                    }
                }
                let remaining = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
                independence = min(independence, remaining)
                if remaining < 1e-12 { return 0 }
                values = values.map { $0 / remaining }
                basis.append(values)
            }
            return independence
        }

        private static func solveLinearSystem(
            _ matrix: inout [[Double]],
            _ rhs: inout [Double],
            size: Int
        ) -> Bool {
            for pivot in 0..<size {
                var selected = pivot
                for row in (pivot + 1)..<size where abs(matrix[row][pivot]) > abs(matrix[selected][pivot]) {
                    selected = row
                }
                guard matrix[selected][pivot].isFinite, abs(matrix[selected][pivot]) >= 1e-16 else {
                    return false
                }
                if selected != pivot {
                    matrix.swapAt(pivot, selected)
                    rhs.swapAt(pivot, selected)
                }
                let diagonal = matrix[pivot][pivot]
                for column in pivot..<size { matrix[pivot][column] /= diagonal }
                rhs[pivot] /= diagonal
                for row in 0..<size where row != pivot {
                    let factor = matrix[row][pivot]
                    for column in pivot..<size { matrix[row][column] -= factor * matrix[pivot][column] }
                    rhs[row] -= factor * rhs[pivot]
                }
            }
            return rhs.allSatisfy { $0.isFinite }
        }

        private static func number(_ value: Double) -> String {
            String(format: "%.2f", value)
        }

        private func deduplicate(_ values: [String]) -> [String] {
            var seen = Set<String>()
            var output: [String] = []
            for value in values where seen.insert(value).inserted {
                output.append(value)
            }
            return output
        }
    }

    // MARK: - 自由函数

    private static func normalize(_ angle: Double) -> Double {
        atan2(sin(angle), cos(angle))
    }
}

private extension Array where Element == String {
    /// 把先前累积的警告补到新结果里（自动扩范围时保留早期提示）。
    func mergingMissing(from previous: [String]) -> [String] {
        var output = self
        for value in previous where !output.contains(value) {
            output.insert(value, at: 0)
        }
        return output
    }
}
