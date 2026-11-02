import Foundation

/// 三分支共用的阿基米德螺旋模型（等螺距）。
///
/// 单位一律是毫米与弧度。约定：
/// - 角度从 +x 轴起、逆时针为正；
/// - 「圈数」指从内半径起累计的圈数（0 在内圈，totalTurns 在外圈）；
/// - 面积线性：`turns(r) = totalTurns · (r² − ri²) / (ro² − ri²)`。
///
/// 螺距由环带面积除以总轨道长反算：`pitch = π(ro² − ri²) / L`。
/// 这是源项目一贯的做法，也是 §2.2 表格里 CD/DVD 自检值的来源。
public struct SpiralModel: Sendable, Equatable {
    public let innerRadiusMm: Double
    public let outerRadiusMm: Double
    public let totalSectors: Int
    public let totalLengthMm: Double

    public init(innerRadiusMm: Double, outerRadiusMm: Double, totalSectors: Int, totalLengthMm: Double) {
        self.innerRadiusMm = innerRadiusMm
        self.outerRadiusMm = outerRadiusMm
        self.totalSectors = totalSectors
        self.totalLengthMm = totalLengthMm
    }

    /// 径向跨度（mm）。
    public var radialSpanMm: Double { outerRadiusMm - innerRadiusMm }

    /// 平均螺距（mm）。总长为 0 时返回 0，避免除零。
    public var pitchMm: Double {
        guard totalLengthMm > 0 else { return 0 }
        return .pi * (outerRadiusMm * outerRadiusMm - innerRadiusMm * innerRadiusMm) / totalLengthMm
    }

    /// 总圈数 `(ro − ri) / pitch`。
    public var totalTurns: Double {
        let pitch = pitchMm
        guard pitch > 0 else { return 0 }
        return radialSpanMm / pitch
    }

    /// 一圈对应的扇区数。
    public var sectorsPerTurn: Double {
        guard totalTurns > 0 else { return 0 }
        return Double(totalSectors) / totalTurns
    }

    /// 每毫米半径对应的圈数（线性近似时常用）。
    public var turnsPerMillimetre: Double {
        guard totalTurns > 0, radialSpanMm > 0 else { return 0 }
        return totalTurns / radialSpanMm
    }

    /// 半径处累计圈数（面积线性，半径超出范围时夹紧）。
    public func turnsAt(radiusMm radius: Double) -> Double {
        turnsAtAreaFraction(areaFraction(radiusMm: radius))
    }

    /// 由累计圈数反算半径。
    public func radiusAt(turns: Double) -> Double {
        guard totalTurns > 0 else { return innerRadiusMm }
        let fraction = min(max(turns / totalTurns, 0), 1)
        return radiusAtAreaFraction(fraction)
    }

    /// 半径处对应的扇区坐标（不含角度分量）。结果落在 0…totalSectors。
    public func sectorCoordinate(radiusMm radius: Double) -> Double {
        Double(totalSectors) * areaFraction(radiusMm: radius)
    }

    /// 半径 + 角度 → 扇区坐标（含连续角度分量），供按图遍历轨道的引擎使用。
    /// 顺时针盘（DVD）由调用方自行取负角度或减方向修正。
    public func sectorCoordinate(radiusMm radius: Double, angleRadians angle: Double) -> Double {
        let turns = turnsAt(radiusMm: radius)
        let angleTurns = angle / (2 * .pi)
        return (turns + angleTurns) * sectorsPerTurn
    }

    /// 由扇区坐标反算半径（sectorCoordinate 的逆）。
    public func radiusAt(sectorCoordinate coordinate: Double) -> Double {
        guard totalSectors > 0 else { return innerRadiusMm }
        let fraction = min(max(coordinate / Double(totalSectors), 0), 1)
        return radiusAtAreaFraction(fraction)
    }

    /// 环带面积占比 `(r² − ri²) / (ro² − ri²)`。
    public func areaFraction(radiusMm radius: Double) -> Double {
        let inner2 = innerRadiusMm * innerRadiusMm
        let range = outerRadiusMm * outerRadiusMm - inner2
        guard range > 0 else { return 0 }
        let clamped = min(max(radius, innerRadiusMm), outerRadiusMm)
        return (clamped * clamped - inner2) / range
    }

    /// 面积占比的反函数。
    public func radiusAtAreaFraction(_ fraction: Double) -> Double {
        let inner2 = innerRadiusMm * innerRadiusMm
        let range = outerRadiusMm * outerRadiusMm - inner2
        let clamped = min(max(fraction, 0), 1)
        return (inner2 + clamped * range).squareRoot()
    }

    private func turnsAtAreaFraction(_ fraction: Double) -> Double {
        totalTurns * fraction
    }
}
