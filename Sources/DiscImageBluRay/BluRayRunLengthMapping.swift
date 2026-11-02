import Foundation

/// 3T / 6T 定灰映射：暗部写偏 3T 数量的 `0xAA`，亮部写偏 6T 数量的 `0x44`。
///
/// 这两个值是对整簇 958,272 个通道位做数字编码统计选出来的（各为 256 个重复字节之首）：
/// 基准 PSN 0x100000 上 `0xAA` 有 265,136 个 3T、`0x44` 有 116,575 个 6T。
/// 它是**图像映射约定，不是实测光学极性**：实际明暗方向要靠实盘标定，
/// 极性由 `invert` 独立控制。
public struct BluRayRunLengthMapping: Sendable, Equatable {
    public static let threeTByte: UInt8 = 0xAA
    public static let sixTByte: UInt8 = 0x44
    /// 二值判定阈值（源项目与 `ToneProfile` 一致）。
    public static let threshold: UInt8 = 128

    public let invert: Bool

    public init(invert: Bool = false) {
        self.invert = invert
    }

    /// 灰度 → 扰码域目标字节。`gray < 128` 视为暗部。
    public func map(gray: UInt8) -> UInt8 {
        let dark = gray < Self.threshold
        let useThreeT = invert ? !dark : dark
        return useThreeT ? Self.threeTByte : Self.sixTByte
    }

    /// 是否把该灰度映射为偏 3T 的字节。
    public func usesThreeT(gray: UInt8) -> Bool {
        let dark = gray < Self.threshold
        return invert ? !dark : dark
    }

    /// 就地映射一整段灰度（性能路径，语义与逐字节 `map` 相同）。
    public func mapGrayBuffer(_ buffer: inout [UInt8]) {
        let darkByte = invert ? Self.sixTByte : Self.threeTByte
        let lightByte = invert ? Self.threeTByte : Self.sixTByte
        for index in 0..<buffer.count {
            buffer[index] = buffer[index] < Self.threshold ? darkByte : lightByte
        }
    }
}
