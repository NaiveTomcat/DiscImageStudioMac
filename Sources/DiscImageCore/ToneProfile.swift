import Foundation

/// 影调：把源图灰度翻译成盘面可记录的层级。
///
/// - `ditherStrength`：0…1（UI 上显示 0–100%）。0 等于源项目早期的硬阈值；
///   大于 0 时按字节样本索引抖动邻级，中调在观看距离下才能还原。
/// - `levels`：2（黑白）或 4（CD 专用的两级中间调）。DVD/BD 固定 2。
/// - `brightness`：−64…64，按 0…255 灰度单位整体平移。
/// - `srgbLinearization`：0…1，sRGB 反伽马线性化的混合强度（0 关闭，1 全量）。
///
/// 这条曲线是 CD / DVD / BD 三条链路**唯一**共享的影调定义：
/// 伽马只改变黑白点密度，不改变盘面反射率。
public struct ToneProfile: Codable, Equatable, Sendable {
    public static let minBrightness = -64
    public static let maxBrightness = 64
    public static let twoLevels = 2
    public static let fourLevels = 4

    public var ditherStrength: Double
    public var levels: Int
    public var brightness: Int
    public var srgbLinearization: Double

    public init(
        ditherStrength: Double = 0.75,
        levels: Int = 2,
        brightness: Int = 0,
        srgbLinearization: Double = 0
    ) {
        self.ditherStrength = ditherStrength
        self.levels = levels
        self.brightness = brightness
        self.srgbLinearization = srgbLinearization
    }

    /// 源项目早期行为：单一 128 阈值、两阶。
    public static let legacyBinary = ToneProfile(ditherStrength: 0, levels: 2, brightness: 0)

    /// 摄影起点：75% 字节级抖动、仍为两阶（新工程默认）。
    public static let photo = ToneProfile(ditherStrength: 0.75, levels: 2, brightness: 0)

    /// 新旧工程通用的默认值。
    public static let `default` = ToneProfile.photo

    /// 是否等价于历史 `grey < 128 ? black : white`。
    public var isLegacyBinary: Bool {
        ditherStrength <= 0 && levels == Self.twoLevels && brightness == 0 && srgbLinearization <= 0
    }

    /// DVD/BD 只支持两阶。
    public var isDvdCompatible: Bool { levels == Self.twoLevels }

    /// 源灰度 → （可选 sRGB 线性化）→ 亮度偏移 → 0…255。
    public func adjustedGray(_ gray: UInt8) -> UInt8 {
        var value = Double(gray) / 255.0
        let linearization = min(max(srgbLinearization, 0), 1)
        if linearization > 0 {
            let linear: Double
            if value <= 0.04045 {
                linear = value / 12.92
            } else {
                linear = pow((value + 0.055) / 1.055, 2.4)
            }
            value += (linear - value) * linearization
        }
        value = min(max(value + Double(brightness) / 255.0, 0), 1)
        return UInt8((value * 255.0).rounded(.toNearestOrAwayFromZero))
    }

    /// 二值判定：`true` = 白（亮）。
    /// - Parameters:
    ///   - gray: 源灰度
    ///   - sampleIndex: 逻辑样本索引（**不是**屏幕坐标；必须能在读回预览里逐字节复现）
    ///   - threshold: 判定阈值，默认 128
    public func useWhite(_ gray: UInt8, sampleIndex: Int64, threshold: Double = 128) -> Bool {
        if isLegacyBinary {
            return Double(gray) >= threshold
        }
        let strength = min(max(ditherStrength, 0), 1)
        let shifted = threshold + strength * 255.0 * (ToneDither.phase(sampleIndex) - 0.5)
        return Double(adjustedGray(gray)) >= shifted
    }

    /// 四阶判定：返回 0…3 的层级索引（0 = 最暗）。
    /// 与源项目 `FourLevelGrayscale` 同构：无抖动时按 64 等宽分箱。
    public func levelIndex(_ gray: UInt8, sampleIndex: Int64) -> Int {
        if levels != Self.fourLevels {
            return useWhite(gray, sampleIndex: sampleIndex) ? 1 : 0
        }
        if ditherStrength <= 0 && brightness == 0 && srgbLinearization <= 0 {
            return Int(gray) >> 6
        }
        let strength = min(max(ditherStrength, 0), 1)
        let normalized = Double(adjustedGray(gray)) / 255.0 * Double(Self.fourLevels - 1)
        let dithered = normalized + strength * (ToneDither.phase(sampleIndex) - 0.5)
        return min(max(Int(dithered.rounded(.toNearestOrAwayFromZero)), 0), Self.fourLevels - 1)
    }

    /// 把用户界面的取值夹进合法范围（滑块取整误差不该让工程打不开）。
    public func normalized() -> ToneProfile {
        ToneProfile(
            ditherStrength: min(max(ditherStrength.isFinite ? ditherStrength : 0, 0), 1),
            levels: levels == Self.fourLevels ? Self.fourLevels : Self.twoLevels,
            brightness: min(max(brightness, Self.minBrightness), Self.maxBrightness),
            srgbLinearization: min(max(srgbLinearization.isFinite ? srgbLinearization : 0, 0), 1)
        )
    }

    /// 严格校验（用于持久化/命令行入参）。
    public func validate(field: String = "tone") throws {
        guard ditherStrength.isFinite, (0...1).contains(ditherStrength) else {
            throw DiscError.invalidGeometry("\(field).ditherStrength 必须是 0…1 的有限数")
        }
        guard levels == Self.twoLevels || levels == Self.fourLevels else {
            throw DiscError.invalidGeometry("\(field).levels 只能是 2 或 4")
        }
        guard (Self.minBrightness...Self.maxBrightness).contains(brightness) else {
            throw DiscError.invalidGeometry("\(field).brightness 必须在 −64…64 之间")
        }
        guard srgbLinearization.isFinite, (0...1).contains(srgbLinearization) else {
            throw DiscError.invalidGeometry("\(field).srgbLinearization 必须是 0…1 的有限数")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case ditherStrength, levels, brightness, srgbLinearization
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ditherStrength = try container.decodeIfPresent(Double.self, forKey: .ditherStrength) ?? 0.75
        levels = try container.decodeIfPresent(Int.self, forKey: .levels) ?? 2
        brightness = try container.decodeIfPresent(Int.self, forKey: .brightness) ?? 0
        srgbLinearization = try container.decodeIfPresent(Double.self, forKey: .srgbLinearization) ?? 0
    }
}

/// 逐字节确定性抖动相位 [0, 1)。
///
/// 用哈希而不是有序矩阵/黄金分割序列：预览每隔 N 个字节取样，任何相干序列
/// 都会与固定步长拍频，画出环状或摩尔纹。哈希能打散子集，稀疏预览看到的是颗粒。
public enum ToneDither {
    public static func phase(_ sampleIndex: Int64) -> Double {
        var value = UInt32(truncatingIfNeeded: sampleIndex) &* 2_654_435_761
        value ^= value >> 16
        value &*= 0x7FEB_352D
        value ^= value >> 15
        value &*= 0x846C_A68B
        value ^= value >> 16
        return Double(value) / 4_294_967_296.0
    }
}
