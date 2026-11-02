import DiscImageCore
import Foundation

/// CD（Compact Disc）的物理参数与几何反算。
///
/// 单位一律毫米与弧度。约定与源项目 `src/DiscImageStudio.Cd/CdDiscParameters.cs` 一致：
///
/// - 2352 字节/扇区、75 扇区/秒（ECMA-130 的 CD-DA 时序）；
/// - 半径按**字节序号**的面积线性插值：`r = sqrt(ri² + f·(ro² − ri²))`，
///   `f = globalByte / totalBytes`；
/// - 角度按 CLV 螺旋推进：`θ = θ0 + 2vT/(ro² − ri²)·(r − ri)`，
///   `T = sectors / 75` 是整盘时长、`v` 是线速度（默认 1200 mm/s）；
/// - 图片坐标 `pixelRadius = (size/2)·r / imageOuterRadiusMm`，画布中心 = 盘心，
///   θ 沿 +x 轴起、逆时针为正。
///
/// 注意：这条链路**没有** CIRC 与 EFM 调制。灰色只体现为音频样本字节的取值
/// （`0x0D`/`0xAA` 等），延迟交织是在字节层面的重排。别在这里补 CIRC。
public struct CdDiscParameters: Sendable, Equatable {
    /// CD 音频/数据扇区的字节数（2352 = 98 帧 × 24 字节）。
    public static let bytesPerSector = 2_352
    /// CD-DA 的每秒扇区数。
    public static let sectorsPerSecond = 75
    /// ECMA-130 标准扫描线速度。
    public static let standardLinearVelocityMmPerSecond = 1_200.0
    /// 源项目的绘图外半径：图可以略超出数据区外缘（数据区外半径通常 56.8 mm）。
    public static let standardImageOuterRadiusMm = 57.5

    public var innerRadiusMm: Double
    public var outerRadiusMm: Double
    public var sectors: Int
    public var linearVelocityMmPerSecond: Double
    /// 起始角度（弧度）；源项目默认 0。
    public var startAngleRadians: Double
    /// 图片画布半宽对应的盘面半径。
    public var imageOuterRadiusMm: Double

    public init(
        innerRadiusMm: Double = DiscPreset.cd80.innerRadiusMm,
        outerRadiusMm: Double = DiscPreset.cd80.outerRadiusMm,
        sectors: Int = DiscPreset.cd80.sectors,
        linearVelocityMmPerSecond: Double = CdDiscParameters.standardLinearVelocityMmPerSecond,
        startAngleRadians: Double = 0,
        imageOuterRadiusMm: Double = CdDiscParameters.standardImageOuterRadiusMm
    ) {
        self.innerRadiusMm = innerRadiusMm
        self.outerRadiusMm = outerRadiusMm
        self.sectors = sectors
        self.linearVelocityMmPerSecond = linearVelocityMmPerSecond
        self.startAngleRadians = startAngleRadians
        self.imageOuterRadiusMm = imageOuterRadiusMm
    }

    /// 从共享的 `DiscGeometry` 派生（CD 只用到半径、扇区数、线速度）。
    public init(geometry: DiscGeometry) {
        self.init(
            innerRadiusMm: geometry.innerRadiusMm,
            outerRadiusMm: geometry.outerRadiusMm,
            sectors: geometry.sectors,
            linearVelocityMmPerSecond: geometry.linearVelocityMmPerSecond
        )
    }

    // MARK: - 派生量

    /// 整盘音频字节数（= sectors × 2352）。
    public var totalBytes: Int { sectors * Self.bytesPerSector }

    /// 整盘时长（秒）。
    public var totalTimeSeconds: Double { Double(sectors) / Double(Self.sectorsPerSecond) }

    /// `ro² − ri²`，采样公式的分母。
    public var radiusSquaredRange: Double {
        outerRadiusMm * outerRadiusMm - innerRadiusMm * innerRadiusMm
    }

    /// 每弧度对应的半径增量分母：`2vT / (ro² − ri²)`。
    public var angleScale: Double {
        2.0 * linearVelocityMmPerSecond * totalTimeSeconds / radiusSquaredRange
    }

    /// 每像素对应的毫米数（画布尺寸 = 图片最长边）。
    public func millimetresPerPixel(imageSize: Int) -> Double {
        imageOuterRadiusMm * 2.0 / Double(imageSize)
    }

    // MARK: - 字节序号 ↔ 盘面坐标

    /// 字节序号 → 盘面半径（mm）。越界序号按源项目语义夹到两端。
    public func radiusFromByte(_ globalByte: Int) -> Double {
        let fraction = min(max(Double(globalByte) / Double(totalBytes), 0), 1)
        return (innerRadiusMm * innerRadiusMm + fraction * radiusSquaredRange).squareRoot()
    }

    /// 半径 → 螺旋转角（弧度）。`r = ri` 处等于起始角。
    public func thetaFromRadius(_ radiusMm: Double) -> Double {
        startAngleRadians + angleScale * (radiusMm - innerRadiusMm)
    }

    /// 字节序号 → （半径，转角）。
    public func polarFromByte(_ globalByte: Int) -> (radiusMm: Double, angleRadians: Double) {
        let radius = radiusFromByte(globalByte)
        return (radius, thetaFromRadius(radius))
    }

    /// 字节序号 → 图片像素坐标（连续坐标，画布中心 = 盘心）。
    ///
    /// 方形画布与源项目 `ImagePointFromByte(globalByte, imageSize)` 完全一致；
    /// 非方形画布用短边的一半作像素半径，保证整张盘不会超出画布。
    public func imagePointFromByte(
        _ globalByte: Int,
        canvasWidth: Int,
        canvasHeight: Int
    ) -> (x: Double, y: Double) {
        let polar = polarFromByte(globalByte)
        let halfExtent = Double(min(canvasWidth, canvasHeight)) / 2.0
        let pixelRadius = halfExtent * polar.radiusMm / imageOuterRadiusMm
        return (
            Double(canvasWidth) / 2.0 + pixelRadius * cos(polar.angleRadians),
            Double(canvasHeight) / 2.0 + pixelRadius * sin(polar.angleRadians)
        )
    }

    /// 方形画布的简写。
    public func imagePointFromByte(_ globalByte: Int, imageSize: Int) -> (x: Double, y: Double) {
        imagePointFromByte(globalByte, canvasWidth: imageSize, canvasHeight: imageSize)
    }

    // MARK: - 校验

    /// 在 `DiscGeometry.validate()` 之外再检查 CD 专属约束。
    public func validate() throws {
        guard innerRadiusMm.isFinite, innerRadiusMm > 0 else {
            throw DiscError.invalidGeometry("CD 内半径必须是正数（当前 \(innerRadiusMm) mm）")
        }
        guard outerRadiusMm.isFinite, outerRadiusMm > innerRadiusMm else {
            throw DiscError.invalidGeometry("CD 外半径必须大于内半径（当前 \(innerRadiusMm) → \(outerRadiusMm) mm）")
        }
        guard sectors > 0 else {
            throw DiscError.invalidGeometry("CD 扇区数必须为正数（当前 \(sectors)）")
        }
        guard linearVelocityMmPerSecond.isFinite, linearVelocityMmPerSecond > 0 else {
            throw DiscError.invalidGeometry("CD 线速度必须为正数（当前 \(linearVelocityMmPerSecond) mm/s）")
        }
        guard startAngleRadians.isFinite else {
            throw DiscError.invalidGeometry("CD 起始角度必须是有限数")
        }
        guard imageOuterRadiusMm.isFinite, imageOuterRadiusMm > 0 else {
            throw DiscError.invalidGeometry("CD 绘图外半径必须是正数（当前 \(imageOuterRadiusMm) mm）")
        }
    }
}
