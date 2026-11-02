import Foundation

/// ISO/IEC 30190:2021 单层 BD-R 的关键常量。
///
/// 这里的数值全部来自源项目 `src/DiscImageStudio.BluRay/` 的编码链与
/// `docs/ADDING_BLURAY.md`；改动它们等于改标准，必须先对照标准原文。
public enum BluRaySpec {
    // MARK: - 扇区与簇

    /// 每扇区用户数据（2048-byte payload）。
    public static let bytesPerSector = 2048
    /// 一个 ECC 簇 = 32 个用户扇区 = 一个 recording unit。
    public static let sectorsPerCluster = 32
    /// 每簇用户数据字节数：65,536。
    public static let payloadBytesPerCluster = bytesPerSector * sectorsPerCluster
    /// 每个 data frame = 2048 payload + 4 EDC = 2052。
    public static let dataFrameBytes = 2052
    /// 每簇 data frame 字节数：32 × 2052 = 65,664 = 304 × 216。
    ///
    /// 这条恒等式就是「32 扇区必须对齐」的算术原因：LDC 是 304 个
    /// RS(248,216) 码字，每个码字 216 个数据字节，刚好铺满一整簇。
    public static let dataBytesPerCluster = sectorsPerCluster * dataFrameBytes
    public static let ldcCodewords = 304
    public static let ldcDataBytes = 216
    public static let ldcParityBytes = 32
    public static let ldccodewordBytes = ldcDataBytes + ldcParityBytes

    // MARK: - ECC 簇（复用前）

    public static let recordingFrames = 496
    public static let eccBytesPerFrame = 155
    public static let eccClusterBytes = recordingFrames * eccBytesPerFrame          // 76,880
    public static let ldcClusterBytes = recordingFrames * 152                        // 75,392
    public static let bisClusterBytes = recordingFrames * 3                          // 1,488
    public static let userControlBytesPerCluster = sectorsPerCluster * 18            // 576

    // MARK: - 调制与 RUB

    public static let channelBitsPerFrame = 1932
    public static let dcControlBitsPerFrame = 28
    public static let modulatedDataBitsPerFrame = 1268
    public static let physicalClusterChannelBits = recordingFrames * channelBitsPerFrame   // 958,272
    public static let runInChannelBits = 2760
    public static let physicalClusterChannelBitsPlusRunIn = runInChannelBits + physicalClusterChannelBits
    public static let runOutChannelBits = 1104
    /// 一个 recording unit（RUB）= run-in + 496 帧 + run-out = 962,136 通道位。
    public static let channelBitsPerRecordingUnit = runInChannelBits + physicalClusterChannelBits + runOutChannelBits
    /// 可选的 Guard_3（不包含在 RUB 的重复跨度里）。
    public static let guard3ChannelBits = 540
    /// 每簇数据侧的 958,272 通道位（不含 run-in/run-out/Guard3）。
    public static let dataChannelBitsPerCluster = physicalClusterChannelBits
    /// 32 个扇区摊到的名义扇区跨度（通道位 / 扇区）。
    public static let channelBitsPerSector = Double(channelBitsPerRecordingUnit) / Double(sectorsPerCluster)

    // MARK: - 几何与地址

    public static let channelBitLengthNm = 74.5
    public static let nominalTrackPitchMicrometres = 0.320
    /// 单层数据区第一个物理扇区号。
    public static let firstLayer0PhysicalSector: UInt32 = 0x0010_0000
    /// 单层 25 GB 的最大扇区数。
    public static let sectorsPerLayer = 12_219_392
    /// 最后一个合法簇起始 PSN（含）。
    public static let lastClusterPhysicalSector: UInt32 = 0x00CA_73E0
    /// 单层数据区簇数。
    public static let clustersPerLayer = sectorsPerLayer / sectorsPerCluster

    /// 显式断言 32 × 2052 = 304 × 216（簇对齐的算术基础）。
    ///
    /// 生成入口与测试都会调用；这里用 `precondition` 而不是 `assert`，
    /// 以便在 release 构建下也能立刻发现有人改了常量。
    public static func validateLayout() {
        precondition(
            sectorsPerCluster * dataFrameBytes == ldcCodewords * ldcDataBytes,
            "32 × 2052 必须等于 304 × 216（当前 \(sectorsPerCluster) × \(dataFrameBytes) ≠ \(ldcCodewords) × \(ldcDataBytes)）"
        )
        precondition(
            channelBitsPerRecordingUnit == 962_136,
            "BD recording unit 必须是 962,136 通道位（当前 \(channelBitsPerRecordingUnit)）"
        )
        precondition(
            physicalClusterChannelBits == recordingFrames * channelBitsPerFrame,
            "物理簇通道位数与 496 × 1932 不一致"
        )
        precondition(
            payloadBytesPerCluster == sectorsPerCluster * bytesPerSector,
            "簇用户字节数必须是 32 × 2048"
        )
    }
}
