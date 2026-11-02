import Foundation

/// DVD 物理编码的固定常量。
///
/// 数值来源与源项目 `DvdEccBlockEncoder` / `DvdDataFrameBuilder` 保持一致（ECMA-267）：
/// 每扇区 38688 通道位 = 13 × 2 × (32 + 1456)，16 扇区 = 1 ECC Block = 619008 通道位。
public enum DvdConstants {
    /// 逻辑扇区（payload）字节数。
    public static let logicalSectorBytes = 2048
    /// 一个 ECC Block 覆盖的扇区数。
    public static let sectorsPerBlock = 16
    /// 每个 payload 的字节数（与逻辑扇区相同，单独命名是为了读代码时不混）。
    public static let payloadBytesPerSector = 2048
    /// 一个 ECC Block 的 payload 字节数。
    public static let payloadBytesPerBlock = sectorsPerBlock * payloadBytesPerSector
    /// 每扇区通道位数。
    public static let channelBitsPerSector = 38_688
    /// 每个 ECC Block 通道位数。
    public static let channelBitsPerBlock = sectorsPerBlock * channelBitsPerSector
    /// 每扇区的 Sync Frame 数（13 行 × 2 帧）。
    public static let syncFramesPerSector = 26
    /// 每 ECC Block 的 Sync Frame 数。
    public static let syncFramesPerBlock = sectorsPerBlock * syncFramesPerSector
    /// 每个 Sync Frame 的字节数。
    public static let bytesPerSyncFrame = 91
    /// 每个 Sync Frame 的通道位数。
    public static let bitsPerSyncFrame = 1488
    /// SYNC 码占用的通道位数。
    public static let syncCodeBits = 32
    /// ECC 矩阵行数（192 数据行 + 16 PO 行）。
    public static let eccRows = 208
    /// ECC 矩阵列数（172 数据列 + 10 PI 列）。
    public static let eccColumns = 182
    /// ECC 数据行数。
    public static let dataRows = 192
    /// ECC 数据列数。
    public static let dataColumns = 172
    /// PI 校验字节数。
    public static let piParityBytes = 10
    /// PO 校验字节数。
    public static let poParityBytes = 16
    /// IED 校验字节数。
    public static let iedParityBytes = 2
    /// 数据帧（含 ID/IED/RSV/EDC）字节数。
    public static let dataFrameBytes = 2064

    /// 物理扇区号偏移：PSN = 0x30000 + LBA（源项目固定约定）。
    public static let physicalSectorNumberOffset: UInt32 = 0x30000

    /// 扰码域里的「黑」：5 次 transition。
    public static let blackScrambledByte: UInt8 = 0xA5
    /// 扰码域里的「白」：2 次 transition。
    public static let whiteScrambledByte: UInt8 = 0x92
    /// 旧镜像回读用：0x66 曾被当作暗灰，现在只识别、不再生成。
    public static let legacyDarkScrambledByte: UInt8 = 0x66
    /// 旧镜像回读用：0xB9 回读为 85 级灰。
    public static let legacyMidScrambledByte: UInt8 = 0xB9
}
