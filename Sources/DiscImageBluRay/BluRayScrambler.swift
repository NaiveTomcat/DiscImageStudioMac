import Foundation

/// BD-R data frame 加扰器（ISO/IEC 30190:2021 §13.4）。
///
/// 16 位 LFSR，抽头 `x¹⁵ + x¹⁴ + x¹² + x³ + 1`；种子由 PSN 的 bit 19…5 给出，
/// s15 恒为 1。同一簇的 32 个扇区共用同一个掩码（源项目 `FillCluster` 的约定）。
/// 加扰与解扰是同一个 XOR 操作。
public enum BluRayScrambler {
    /// 生成长度 `length`（默认 2052 = 一个完整 data frame）的掩码。
    public static func mask(physicalSectorNumber: UInt32, length: Int = BluRaySpec.dataFrameBytes) -> [UInt8] {
        precondition(length >= 0 && length <= BluRaySpec.dataFrameBytes, "BD 加扰序列不能超过一个 data frame")
        var state = UInt16(0x8000 | UInt16((physicalSectorNumber >> 5) & 0x7FFF))
        var result = [UInt8](repeating: 0, count: length)
        for index in 0..<length {
            result[index] = UInt8(state & 0xFF)
            for _ in 0..<8 {
                let feedback = ((state >> 15) ^ (state >> 14) ^ (state >> 12) ^ (state >> 3)) & 1
                state = (state << 1) | feedback
            }
        }
        return result
    }

    /// 就地加扰 / 解扰（同一操作），从 data frame 第 0 字节开始。
    public static func transform(_ data: inout [UInt8], physicalSectorNumber: UInt32) {
        precondition(data.count <= BluRaySpec.dataFrameBytes, "一次只能处理一个 data frame")
        let sequence = mask(physicalSectorNumber: physicalSectorNumber, length: data.count)
        for index in 0..<data.count {
            data[index] ^= sequence[index]
        }
    }

    /// 与 `transform` 等价的纯函数版本。
    public static func scrambled(_ data: [UInt8], physicalSectorNumber: UInt32) -> [UInt8] {
        precondition(data.count <= BluRaySpec.dataFrameBytes, "一次只能处理一个 data frame")
        let sequence = mask(physicalSectorNumber: physicalSectorNumber, length: data.count)
        return zip(data, sequence).map { $0 ^ $1 }
    }
}
