import DiscImageCore
import Foundation

/// Data Frame 组装：ID(IED) + RSV(6×0x00) + 2048 字节 payload + EDC，再按 PSN 扰码。
///
/// 与源项目 `DvdDataFrameBuilder.cs` 一一对应。固定约定（HANDOFF §2.1）：
/// Sector Information 为 `0x00`、DVD-R Data Frame 的 RSV 为六个 `0x00`、
/// PSN = 0x30000 + LBA。
enum DvdDataFrameBuilder {
    /// 16 个扰码器初始值（ECMA-267 规定的 16 个预设种子）。
    private static let scramblerPresets: [UInt16] = [
        0x0001, 0x5500, 0x0002, 0x2A00,
        0x0004, 0x5400, 0x0008, 0x2800,
        0x0010, 0x5000, 0x0020, 0x2001,
        0x0040, 0x4002, 0x0080, 0x0005,
    ]

    /// 16 × 2048 字节的扰码掩码表，进程内只建一次。
    private static let payloadScramblerMasks: [[UInt8]] = {
        scramblerPresets.map { preset in
            var scrambler = preset
            var mask = [UInt8](repeating: 0, count: DvdConstants.payloadBytesPerSector)
            for index in 0..<mask.count {
                mask[index] = UInt8(truncatingIfNeeded: scrambler)
                for _ in 0..<8 {
                    let feedback = ((scrambler >> 14) ^ (scrambler >> 10)) & 1
                    scrambler = ((scrambler &<< 1) | feedback) & 0x7FFF
                }
            }
            return mask
        }
    }()

    /// 某个物理扇区使用的扰码掩码。掩码只取决于 `(PSN >> 4) & 0xF`。
    static func payloadScramblerMask(physicalSectorNumber: UInt32) -> [UInt8] {
        payloadScramblerMasks[Int((physicalSectorNumber >> 4) & 0xF)]
    }

    /// 组一个未扰码的 Data Frame（2064 字节）。
    static func buildDataFrame(payload: ArraySlice<UInt8>, physicalSectorNumber: UInt32) -> [UInt8] {
        precondition(payload.count == DvdConstants.payloadBytesPerSector)
        precondition(physicalSectorNumber <= 0x00FF_FFFF, "DVD PSN 是 24 位值")
        var frame = [UInt8](repeating: 0, count: DvdConstants.dataFrameBytes)
        // Sector Information：单层 Data Zone 固定 0x00。
        frame[0] = 0x00
        frame[1] = UInt8((physicalSectorNumber >> 16) & 0xFF)
        frame[2] = UInt8((physicalSectorNumber >> 8) & 0xFF)
        frame[3] = UInt8(physicalSectorNumber & 0xFF)
        let ied = ReedSolomon.iedParity(frame[0..<4])
        frame[4] = ied[0]
        frame[5] = ied[1]
        // 6..<12 保持 0x00：DVD-R Data Frame RSV。
        frame.replaceSubrange(12..<2060, with: payload)
        let edc = computeEdc(frame, count: 2060)
        frame[2060] = UInt8((edc >> 24) & 0xFF)
        frame[2061] = UInt8((edc >> 16) & 0xFF)
        frame[2062] = UInt8((edc >> 8) & 0xFF)
        frame[2063] = UInt8(edc & 0xFF)
        return frame
    }

    /// 组 Data Frame 并扰码 payload 区（第 12..2059 字节）。
    static func buildScrambledFrame(payload: ArraySlice<UInt8>, physicalSectorNumber: UInt32) -> [UInt8] {
        var frame = buildDataFrame(payload: payload, physicalSectorNumber: physicalSectorNumber)
        scrambleMainData(&frame, physicalSectorNumber: physicalSectorNumber)
        return frame
    }

    /// 就地扰码 payload 区（幂等：再调用一次即还原）。
    static func scrambleMainData(_ frame: inout [UInt8], physicalSectorNumber: UInt32) {
        precondition(frame.count == DvdConstants.dataFrameBytes)
        let mask = payloadScramblerMask(physicalSectorNumber: physicalSectorNumber)
        for index in 0..<DvdConstants.payloadBytesPerSector {
            frame[12 + index] ^= mask[index]
        }
    }

    /// EDC：CRC-32 风格多项式 `0x80000011`（去掉最高位），初值 0，末补 32 个零。
    static func computeEdc(_ data: [UInt8], count: Int) -> UInt32 {
        let polynomial: UInt32 = 0x8000_0011
        var remainder: UInt32 = 0
        var consumed = 0
        for value in data {
            if consumed == count { break }
            consumed += 1
            var bit = 7
            while bit >= 0 {
                let input = UInt32((value >> UInt8(bit)) & 1)
                let feedback = (remainder >> 31) ^ input
                remainder = remainder &<< 1
                if feedback != 0 {
                    remainder ^= polynomial
                }
                bit -= 1
            }
        }
        for _ in 0..<32 {
            let feedback = remainder >> 31
            remainder = remainder &<< 1
            if feedback != 0 {
                remainder ^= polynomial
            }
        }
        return remainder
    }

    /// 校验 Data Frame 末尾 4 字节 EDC 是否与内容匹配。
    static func hasValidEdc(_ frame: [UInt8]) -> Bool {
        guard frame.count == DvdConstants.dataFrameBytes else { return false }
        let expected = (UInt32(frame[2060]) << 24) | (UInt32(frame[2061]) << 16)
            | (UInt32(frame[2062]) << 8) | UInt32(frame[2063])
        return expected == computeEdc(Array(frame[0..<2060]), count: 2060)
    }
}
