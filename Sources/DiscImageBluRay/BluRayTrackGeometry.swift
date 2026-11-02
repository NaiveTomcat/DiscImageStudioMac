import Foundation
import DiscImageCore

/// 盘面轨迹上的一点（盘片固定坐标系，+Y 向上，角度逆时针）。
public struct BluRayTrackPoint: Sendable, Equatable {
    public let radiusMm: Double
    public let angleRadians: Double
    public var xMm: Double { radiusMm * cos(angleRadians) }
    public var yMm: Double { radiusMm * sin(angleRadians) }

    public init(radiusMm: Double, angleRadians: Double) {
        self.radiusMm = radiusMm
        self.angleRadians = angleRadians
    }
}

/// 恒定轨距的名义 recording-unit 几何（ISO/IEC 30190 §14/§15）。
///
/// 总轨长按「簇数 × 962,136 通道位 × 74.5 nm」计算（含 run-in/run-out），
/// 再用阿基米德螺旋的精确弧长原函数反求轨距 `b`（每弧度半径增量）：
///
/// ```
/// L(r) = (r·√(r²+b²) + b²·asinh(r/b)) / (2b)
/// ```
///
/// 最后一段轨道到达设置的外半径。注意这是**名义**几何：不包含驱动器的缺陷替换、
/// 备用区或实测盘片的半径/轨距偏差（那些要靠标定）。
public struct BluRayTrackGeometry: Sendable {
    public let innerRadiusMm: Double
    public let outerRadiusMm: Double
    public let totalSectors: Int
    public let trackLengthPerLayerMm: Double
    public let growthPerRadian: Double
    public let startAngleRadians: Double
    private let innerPrimitive: Double

    public init(
        innerRadiusMm: Double,
        outerRadiusMm: Double,
        totalSectors: Int,
        startAngleDegrees: Double = 0
    ) throws {
        guard innerRadiusMm.isFinite, innerRadiusMm > 0, outerRadiusMm.isFinite,
              outerRadiusMm > innerRadiusMm, outerRadiusMm <= 60 else {
            throw DiscError.invalidGeometry("蓝光数据区半径必须满足 0 < 内半径 < 外半径 ≤ 60 mm")
        }
        guard totalSectors > 0, totalSectors % BluRaySpec.sectorsPerCluster == 0,
              totalSectors <= BluRaySpec.sectorsPerLayer else {
            throw DiscError.invalidGeometry("蓝光总扇区数必须是 32 的正倍数且不超过 \(BluRaySpec.sectorsPerLayer)")
        }
        guard startAngleDegrees.isFinite else {
            throw DiscError.invalidGeometry("蓝光起始角必须是有限数")
        }
        // 总轨长按「簇数 × recording unit 通道位 × 位长」计算。
        let trackLength = Double(totalSectors) / Double(BluRaySpec.sectorsPerCluster)
            * Double(BluRaySpec.channelBitsPerRecordingUnit)
            * BluRaySpec.channelBitLengthNm * 1e-6

        // 二分求 b，使 L(ro) − L(ri) = 总轨长。
        var low = 1e-15
        var high = 1.0
        while BluRayTrackGeometry.primitive(outerRadiusMm, high) - BluRayTrackGeometry.primitive(innerRadiusMm, high)
            > trackLength {
            high *= 2
        }
        for _ in 0..<100 {
            let middle = (low + high) / 2
            let length = BluRayTrackGeometry.primitive(outerRadiusMm, middle)
                - BluRayTrackGeometry.primitive(innerRadiusMm, middle)
            if length > trackLength { low = middle } else { high = middle }
        }
        let growth = (low + high) / 2

        self.innerRadiusMm = innerRadiusMm
        self.outerRadiusMm = outerRadiusMm
        self.totalSectors = totalSectors
        self.trackLengthPerLayerMm = trackLength
        self.startAngleRadians = (startAngleDegrees.truncatingRemainder(dividingBy: 360)) * .pi / 180
        self.growthPerRadian = growth
        self.innerPrimitive = BluRayTrackGeometry.primitive(innerRadiusMm, growth)
    }

    /// 有效轨距（µm）：`2πb`。名义值应为 0.320 µm。
    public var effectiveTrackPitchMicrometres: Double { 2 * Double.pi * growthPerRadian * 1000 }

    /// 每通道位对应的轨道长度（mm）。
    public var millimetresPerChannelBit: Double {
        trackLengthPerLayerMm / Double(totalSectors)
            / (Double(BluRaySpec.channelBitsPerRecordingUnit) / Double(BluRaySpec.sectorsPerCluster))
    }

    /// 扇区坐标 → 盘面轨迹点。`sectorPosition` 落在 0…totalSectors。
    public func trackPoint(sectorPosition: Double) throws -> BluRayTrackPoint {
        guard sectorPosition.isFinite, sectorPosition >= 0, sectorPosition <= Double(totalSectors) else {
            throw DiscError.invalidGeometry("扇区坐标必须在 0…\(totalSectors)（当前 \(sectorPosition)）")
        }
        let progress = sectorPosition / Double(totalSectors)
        let target = progress * trackLengthPerLayerMm
        // 薄螺旋下初值已经很接近，Newton 两步足够；极薄/异常几何保留 8 步。
        var radius = (innerRadiusMm * innerRadiusMm + 2 * growthPerRadian * target).squareRoot()
        let iterations = growthPerRadian <= 0.01 ? 2 : 8
        for _ in 0..<iterations {
            let error = BluRayTrackGeometry.primitive(radius, growthPerRadian) - innerPrimitive - target
            let slope = (radius * radius + growthPerRadian * growthPerRadian).squareRoot()
            radius = min(max(radius - error * growthPerRadian / slope, innerRadiusMm), outerRadiusMm)
        }
        if progress == 0 { radius = innerRadiusMm }
        if progress == 1 { radius = outerRadiusMm }
        // 盘片在固定光学头下逆时针转，下一个材料点的极角因此递减。
        let angle = startAngleRadians - (radius - innerRadiusMm) / growthPerRadian
        return BluRayTrackPoint(radiusMm: radius, angleRadians: angle)
    }

    /// 轨迹点处的单位切向量（供取样复用优化使用）。
    public func unitTangent(xMm x: Double, yMm y: Double, radiusMm radius: Double) -> (x: Double, y: Double) {
        let length = (radius * radius + growthPerRadian * growthPerRadian).squareRoot()
        return ((growthPerRadian * (x / radius) + y) / length,
                (growthPerRadian * (y / radius) - x) / length)
    }

    static func primitive(_ radius: Double, _ b: Double) -> Double {
        (radius * (radius * radius + b * b).squareRoot() + b * b * asinh(radius / b)) / (2 * b)
    }
}
