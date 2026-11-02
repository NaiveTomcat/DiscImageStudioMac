import Foundation

/// 一张盘片的数据区几何。
///
/// 三种介质共用此结构，各自只填自己需要的字段：
/// - CD：`linearVelocityMmPerSecond`（ECMA-130 标准 1200 mm/s）
/// - DVD：`channelBitLengthNm`（默认 133.3 nm）与可选的三次轨距系数
/// - BD：`invertMapping`（3T/6T 定灰后的极性反转）
///
/// `totalLengthMm` 与 `spiral` 都是派生量，不参与 Codable。
public struct DiscGeometry: Codable, Equatable, Sendable {
    // 编码常量（源项目硬编码值，不要改）
    public static let dvdChannelBitsPerSector = 38_688
    public static let dvdSectorsPerBlock = 16
    public static let dvdChannelBitsPerBlock = 619_008
    public static let bluRayChannelBitsPerCluster = 962_136
    public static let bluRayChannelBitLengthNm = 74.5
    public static let bluRaySectorsPerCluster = 32
    public static let bluRaySingleLayerSectors = 12_219_392

    public var family: DiscFamily
    public var innerRadiusMm: Double
    public var outerRadiusMm: Double
    public var sectors: Int
    public var linearVelocityMmPerSecond: Double
    public var channelBitLengthNm: Double
    public var pitchLinear: Double
    public var pitchQuadratic: Double
    public var pitchCubic: Double
    public var invertMapping: Bool

    public init(
        family: DiscFamily,
        innerRadiusMm: Double,
        outerRadiusMm: Double,
        sectors: Int,
        linearVelocityMmPerSecond: Double = 1200,
        channelBitLengthNm: Double = 133.3,
        pitchLinear: Double = 0,
        pitchQuadratic: Double = 0,
        pitchCubic: Double = 0,
        invertMapping: Bool = false
    ) {
        self.family = family
        self.innerRadiusMm = innerRadiusMm
        self.outerRadiusMm = outerRadiusMm
        self.sectors = sectors
        self.linearVelocityMmPerSecond = linearVelocityMmPerSecond
        self.channelBitLengthNm = channelBitLengthNm
        self.pitchLinear = pitchLinear
        self.pitchQuadratic = pitchQuadratic
        self.pitchCubic = pitchCubic
        self.invertMapping = invertMapping
    }

    /// 总轨道长（mm），三条公式见 HANDOFF §2.2。
    public var totalLengthMm: Double {
        switch family {
        case .cd:
            return (Double(sectors) / 75.0) * linearVelocityMmPerSecond
        case .dvd:
            return Double(sectors) * Double(Self.dvdChannelBitsPerSector) * channelBitLengthNm * 1e-6
        case .bluRay:
            return (Double(sectors) / Double(Self.bluRaySectorsPerCluster))
                * Double(Self.bluRayChannelBitsPerCluster)
                * Self.bluRayChannelBitLengthNm * 1e-6
        }
    }

    /// 等螺距螺旋模型（DVD 的三次轨距修正由 `DiscImageDvd` 另行处理）。
    public var spiral: SpiralModel {
        SpiralModel(
            innerRadiusMm: innerRadiusMm,
            outerRadiusMm: outerRadiusMm,
            totalSectors: sectors,
            totalLengthMm: totalLengthMm
        )
    }

    /// 是否带三次轨距分布（只有实测 DVD 预设会用）。
    public var hasCubicPitch: Bool {
        pitchLinear != 0 || pitchQuadratic != 0 || pitchCubic != 0
    }

    /// 归一化半径处的轨距系数 `1 + c1x + c2x² + c3x³`（x = (r−ri)/(ro−ri)）。
    public func pitchFactor(normalizedRadius x: Double) -> Double {
        1 + pitchLinear * x + pitchQuadratic * x * x + pitchCubic * x * x * x
    }

    /// 校验几何是否可编码。错误信息直接面向用户。
    public func validate() throws {
        guard innerRadiusMm.isFinite, innerRadiusMm > 0 else {
            throw DiscError.invalidGeometry("内半径必须是正数（当前 \(innerRadiusMm) mm）")
        }
        guard outerRadiusMm.isFinite, outerRadiusMm > innerRadiusMm else {
            throw DiscError.invalidGeometry("外半径必须大于内半径（当前 \(innerRadiusMm) → \(outerRadiusMm) mm）")
        }
        guard outerRadiusMm <= 60.5 else {
            throw DiscError.invalidGeometry("外半径不能超过 60 mm（当前 \(outerRadiusMm) mm）")
        }
        guard sectors > 0 else {
            throw DiscError.invalidGeometry("扇区数必须为正数（当前 \(sectors)）")
        }
        switch family {
        case .cd:
            guard linearVelocityMmPerSecond > 0, linearVelocityMmPerSecond.isFinite else {
                throw DiscError.invalidGeometry("CD 线速度必须为正数")
            }
        case .dvd:
            guard sectors % Self.dvdSectorsPerBlock == 0 else {
                throw DiscError.invalidGeometry("DVD 扇区数必须是 16 的整数倍（当前 \(sectors)）")
            }
            guard channelBitLengthNm > 0, channelBitLengthNm.isFinite else {
                throw DiscError.invalidGeometry("DVD 通道位长必须为正数")
            }
            if hasCubicPitch, !Self.pitchPolynomialIsPositive(pitchLinear, pitchQuadratic, pitchCubic) {
                throw DiscError.invalidGeometry("三次轨距系数必须保证 1 + c1x + c2x² + c3x³ 在 0…1 上恒正")
            }
        case .bluRay:
            guard sectors % Self.bluRaySectorsPerCluster == 0 else {
                throw DiscError.invalidGeometry("蓝光扇区数必须是 32 的整数倍（当前 \(sectors)）")
            }
            guard sectors <= Self.bluRaySingleLayerSectors else {
                throw DiscError.invalidGeometry("单层蓝光最多 \(Self.bluRaySingleLayerSectors) 个扇区")
            }
            guard !hasCubicPitch else {
                throw DiscError.unsupported("蓝光不支持三次轨距分布")
            }
        }
    }

    /// 在 0…1 上采样判断三次多项式是否恒正（端点 + 20 个内部点，足够挡住用户误填）。
    static func pitchPolynomialIsPositive(_ c1: Double, _ c2: Double, _ c3: Double) -> Bool {
        guard c1.isFinite, c2.isFinite, c3.isFinite else { return false }
        let samples = 20
        for index in 0...samples {
            let x = Double(index) / Double(samples)
            let value = 1 + c1 * x + c2 * x * x + c3 * x * x * x
            if value <= 0 { return false }
        }
        return true
    }

    /// 一次 ECC Block 覆盖的通道位数（DVD）。
    public var channelBitsPerBlock: Int? {
        family == .dvd ? Self.dvdChannelBitsPerBlock : nil
    }

    // MARK: - Codable
    //
    // 向后兼容：缺字段的旧工程文件按默认值补齐，避免打开即报错。

    private enum CodingKeys: String, CodingKey {
        case family, innerRadiusMm, outerRadiusMm, sectors
        case linearVelocityMmPerSecond, channelBitLengthNm
        case pitchLinear, pitchQuadratic, pitchCubic, invertMapping
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        family = try container.decode(DiscFamily.self, forKey: .family)
        innerRadiusMm = try container.decode(Double.self, forKey: .innerRadiusMm)
        outerRadiusMm = try container.decode(Double.self, forKey: .outerRadiusMm)
        sectors = try container.decode(Int.self, forKey: .sectors)
        linearVelocityMmPerSecond = try container.decodeIfPresent(Double.self, forKey: .linearVelocityMmPerSecond) ?? 1200
        channelBitLengthNm = try container.decodeIfPresent(Double.self, forKey: .channelBitLengthNm) ?? 133.3
        pitchLinear = try container.decodeIfPresent(Double.self, forKey: .pitchLinear) ?? 0
        pitchQuadratic = try container.decodeIfPresent(Double.self, forKey: .pitchQuadratic) ?? 0
        pitchCubic = try container.decodeIfPresent(Double.self, forKey: .pitchCubic) ?? 0
        invertMapping = try container.decodeIfPresent(Bool.self, forKey: .invertMapping) ?? false
    }
}
