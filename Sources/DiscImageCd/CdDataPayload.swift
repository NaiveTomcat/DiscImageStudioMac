import DiscImageCore
import Foundation

/// CD-ROM Mode 1 数据盘的**绘图区补偿**原语。
///
/// 数据盘（选文件夹 → `.iso`）的布局由工作包 A 的 ISO9660 写入器规划：哪些 LBA 放
/// 文件系统、哪些 LBA 留给绘图。文件系统字节原样写出；**绘图区**的每个 2048 字节
/// payload 必须先经过下面两步补偿，才能在刻成光盘、光驱做过扰码与相邻字节交换之后
/// 还原成我们想要的图案（源项目 `CdDataImageGenerator.cs` 的同一套推导）：
///
/// 1. `physicalByte(lba:payloadIndex:)` 把「Mode 1 扇区的 payload 位置」反查成
///    「音频流的逻辑字节序号」，这样采样点就是该字节最终落在盘面上的位置；
/// 2. `drawingPayload(lba:sampler:tone:)` 按调色板取字节，再 XOR 上 ECMA-130
///    Annex B 的扰码掩码（15 位 LFSR `x^15 + x + 1`，种子 1，从扇区第 12 字节起算）。
///
/// 记录后端（驱动器固件 / IMAPI）会补同步头、EDC/ECC 与模式字节，这里不重复。
/// **不要在 `DiscImageCd` 里另写 ISO9660**：目录树、路径表、Joliet 都由工作包 A 负责。
public enum CdDataPayload {
    /// Mode 1 扇区的 payload 字节数。
    public static let payloadBytesPerSector = 2_048
    /// payload 在 2352 字节扇区里的起始偏移（12 字节同步头 + 4 字节头）。
    public static let payloadOffset = 16

    /// 扰码推导出来的「逻辑字节 → 文件位置」的反表。
    ///
    /// `inverseFileOffsets[(j + fileOffset(j % 24)) % 24] = −fileOffset(j % 24)`，
    /// 也就是说物理位置 `p`（已做相邻字节交换）对应的逻辑字节是
    /// `p + inverseFileOffsets[p % 24]`。
    public static let inverseFileOffsets: [Int] = buildInverseFileOffsets()

    /// ECMA-130 Annex B 的扰码掩码，覆盖扇区第 12 字节到第 2351 字节（2340 字节）。
    public static let scrambleMask: [UInt8] = buildScrambleMask()

    /// Mode 1 扇区里第 `payloadIndex` 个 payload 字节对应的逻辑字节序号。
    ///
    /// - Parameters:
    ///   - lba: 扇区号（从 0 起）
    ///   - payloadIndex: payload 内偏移（0…2047）
    public static func physicalByte(lba: Int, payloadIndex: Int) -> Int {
        // 相邻字节交换（^ 1）在扰码之后、CIRC 之前发生，所以先交换再反查延迟表。
        let frameByte = (lba * CdDiscParameters.bytesPerSector + payloadOffset + payloadIndex) ^ 1
        let column = ((frameByte % CddaInterleaveTable.bytesPerFrame) + CddaInterleaveTable.bytesPerFrame)
            % CddaInterleaveTable.bytesPerFrame
        return frameByte + inverseFileOffsets[column]
    }

    /// 扰码掩码里与 payload 第 `payloadIndex` 字节对应的位置。
    public static func scrambleIndex(forPayloadIndex payloadIndex: Int) -> Int {
        payloadIndex + payloadOffset - 12
    }

    /// 生成绘图区某个扇区的 2048 字节 payload（已采样、已调色、已扰码）。
    ///
    /// 调用方只需把返回值原样写进 `.iso` 的对应扇区 payload 位置。
    public static func drawingPayload(
        lba: Int,
        sampler: CdImageSampler,
        tone: ToneProfile
    ) -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: payloadBytesPerSector)
        for index in 0..<payloadBytesPerSector {
            let physical = physicalByte(lba: lba, payloadIndex: index)
            let value = sampler.paletteByte(atByte: physical, tone: tone)
            payload[index] = value ^ scrambleMask[scrambleIndex(forPayloadIndex: index)]
        }
        return payload
    }

    // MARK: - 建表

    private static func buildInverseFileOffsets() -> [Int] {
        let count = CddaInterleaveTable.bytesPerFrame
        var inverse = [Int](repeating: 0, count: count)
        for logical in 0..<count {
            let displacement = CddaInterleaveTable.fileOffsets[logical]
            let column = ((logical + displacement) % count + count) % count
            inverse[column] = -displacement
        }
        return inverse
    }

    /// ECMA-130 Annex B：`x^15 + x + 1`，种子 1，最低位先出。
    private static func buildScrambleMask() -> [UInt8] {
        let length = CdDiscParameters.bytesPerSector - 12
        var mask = [UInt8](repeating: 0, count: length)
        var state = 1
        for index in 0..<length {
            var byte: UInt8 = 0
            for bit in 0..<8 {
                byte |= UInt8(state & 1) << UInt8(bit)
                state = (state >> 1) | (((state ^ (state >> 1)) & 1) << 14)
            }
            mask[index] = byte
        }
        return mask
    }
}
