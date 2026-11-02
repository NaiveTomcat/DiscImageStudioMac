import DiscImageCore
import Foundation

/// 一个 ECC Block 的通道位（NRZI 后的物理电平，1 = land = 白，0 = pit = 黑）。
public struct DvdPhysicalBlock: Equatable, Sendable {
    /// 619008 个电平（0/1）。
    public let channelLevels: [UInt8]
    /// 该 Block 第一个扇区的物理扇区号。
    public let firstPhysicalSectorNumber: UInt32
    /// 出口调制边界（可串到下一个 Block，保证跨 Block 的 DSV/电平连续）。
    public let finalBoundary: DvdModulationBoundary

    public init(channelLevels: [UInt8], firstPhysicalSectorNumber: UInt32, finalBoundary: DvdModulationBoundary) {
        self.channelLevels = channelLevels
        self.firstPhysicalSectorNumber = firstPhysicalSectorNumber
        self.finalBoundary = finalBoundary
    }
}

/// DVD 物理编码链的公开入口：扰码 → ECC（PI/PO/IED）→ EFMPlus（双流 DSV）→ NRZI。
///
/// 说明：DVD 的 `.iso` 输出只包含 2048 字节/扇区的 payload（ECC 由刻录机固件生成，
/// 和源项目一致）。这个类型用于**验证与预览**：给定 payload 能算出完整通道位，
/// 供测试断言 RLL(2,10)、每 Block 619008 位、PI/PO 零余数等不变量。
public enum DvdChannelEncoder {
    // MARK: - 物理扇区号

    /// LBA → PSN（0x30000 + LBA）。
    public static func physicalSectorNumber(
        lba: Int,
        psnOffset: UInt32 = DvdConstants.physicalSectorNumberOffset
    ) throws -> UInt32 {
        guard lba >= 0, lba <= 0x00FF_FFFF else {
            throw DiscError.encoding("LBA 越界：\(lba)")
        }
        let psn = UInt32(lba) &+ psnOffset
        guard psn <= 0x00FF_FFFF else {
            throw DiscError.encoding("PSN 超出 24 位范围：0x\(String(psn, radix: 16))")
        }
        return psn
    }

    // MARK: - Data Frame / ECC

    /// 单个扇区的 Data Frame（未扰码，2064 字节）。
    public static func dataFrame(payload: [UInt8], physicalSectorNumber: UInt32) throws -> [UInt8] {
        guard payload.count == DvdConstants.payloadBytesPerSector else {
            throw DiscError.encoding("一个扇区的 payload 必须是 \(DvdConstants.payloadBytesPerSector) 字节")
        }
        return DvdDataFrameBuilder.buildDataFrame(
            payload: payload[...],
            physicalSectorNumber: physicalSectorNumber
        )
    }

    /// 单个扇区的 Data Frame（已扰码，2064 字节）。
    public static func scrambledFrame(payload: [UInt8], physicalSectorNumber: UInt32) throws -> [UInt8] {
        guard payload.count == DvdConstants.payloadBytesPerSector else {
            throw DiscError.encoding("一个扇区的 payload 必须是 \(DvdConstants.payloadBytesPerSector) 字节")
        }
        return DvdDataFrameBuilder.buildScrambledFrame(
            payload: payload[...],
            physicalSectorNumber: physicalSectorNumber
        )
    }

    /// 16 扇区 payload → ECC 矩阵（208 × 182，未交织）。
    public static func eccBytes(
        payloads: [UInt8],
        firstLba: Int,
        psnOffset: UInt32 = DvdConstants.physicalSectorNumberOffset
    ) throws -> [UInt8] {
        let (firstPsn, _) = try validateBlockInput(payloads: payloads, firstLba: firstLba, psnOffset: psnOffset)
        return DvdEccBlockBuilder.buildEccBytes(payloads: payloads, firstPsn: firstPsn)
    }

    /// 16 扇区 payload → 记录帧（208 × 182，已交织）。
    public static func recordingFrames(
        payloads: [UInt8],
        firstLba: Int,
        psnOffset: UInt32 = DvdConstants.physicalSectorNumberOffset
    ) throws -> [UInt8] {
        let (firstPsn, _) = try validateBlockInput(payloads: payloads, firstLba: firstLba, psnOffset: psnOffset)
        return DvdEccBlockBuilder.buildRecordingFrames(payloads: payloads, firstPsn: firstPsn)
    }

    /// 增量重建记录帧（结果与完整重建逐字节一致）。
    public static func updatedRecordingFrames(
        currentPayloads: [UInt8],
        updatedPayloads: [UInt8],
        currentRecordingFrames: [UInt8],
        firstLba: Int,
        psnOffset: UInt32 = DvdConstants.physicalSectorNumberOffset
    ) throws -> [UInt8] {
        let (firstPsn, _) = try validateBlockInput(payloads: currentPayloads, firstLba: firstLba, psnOffset: psnOffset)
        guard updatedPayloads.count == DvdConstants.payloadBytesPerBlock else {
            throw DiscError.encoding("一个 ECC Block 需要 \(DvdConstants.payloadBytesPerBlock) 字节 payload")
        }
        guard currentRecordingFrames.count == DvdConstants.eccRows * DvdConstants.eccColumns else {
            throw DiscError.encoding("记录帧必须是 \(DvdConstants.eccRows) × \(DvdConstants.eccColumns) 字节")
        }
        return DvdEccBlockBuilder.updateRecordingFrames(
            currentPayloads: currentPayloads,
            updatedPayloads: updatedPayloads,
            currentRecordingFrames: currentRecordingFrames,
            firstPsn: firstPsn
        )
    }

    // MARK: - 通道位

    /// 把 16 扇区 payload 编码成完整通道位（619008 个电平）。
    public static func encodeBlock(
        payloads: [UInt8],
        firstLba: Int,
        psnOffset: UInt32 = DvdConstants.physicalSectorNumberOffset,
        initialBoundary: DvdModulationBoundary = .standard
    ) throws -> DvdPhysicalBlock {
        let (firstPsn, _) = try validateBlockInput(payloads: payloads, firstLba: firstLba, psnOffset: psnOffset)
        let boundary = try initialBoundary.validated()
        let frames = DvdEccBlockBuilder.buildRecordingFrames(payloads: payloads, firstPsn: firstPsn)
        return try encodeRecordingFrames(frames, firstPsn: firstPsn, initialBoundary: boundary)
    }

    /// 记录帧 → 通道位。分开暴露是为了让「增量重建 + 重新调制」不必再算一遍 ECC。
    public static func encodeRecordingFrames(
        _ frames: [UInt8],
        firstLba: Int,
        psnOffset: UInt32 = DvdConstants.physicalSectorNumberOffset,
        initialBoundary: DvdModulationBoundary = .standard
    ) throws -> DvdPhysicalBlock {
        guard frames.count == DvdConstants.eccRows * DvdConstants.eccColumns else {
            throw DiscError.encoding("记录帧必须是 \(DvdConstants.eccRows) × \(DvdConstants.eccColumns) 字节")
        }
        let firstPsn = try physicalSectorNumber(lba: firstLba, psnOffset: psnOffset)
        guard firstPsn & 0xF == 0 else {
            throw DiscError.encoding("ECC Block 的首个 PSN 必须 16 扇区对齐（当前 0x\(String(firstPsn, radix: 16))）")
        }
        return try encodeRecordingFrames(
            frames,
            firstPsn: firstPsn,
            initialBoundary: try initialBoundary.validated()
        )
    }

    /// payload 第 `payloadIndex` 字节的码字中心，相对 Block 起始的通道位偏移。
    public static func payloadChannelOffset(_ payloadIndex: Int) throws -> Int {
        guard payloadIndex >= 0, payloadIndex < DvdConstants.payloadBytesPerBlock else {
            throw DiscError.encoding("payload 下标越界：\(payloadIndex)")
        }
        return DvdEccBlockBuilder.payloadDirectChannelOffset(payloadIndex) + 8
    }

    /// 记录帧里第 `syncFrameIndex` 个 Sync Frame 的 SYNC 类别。
    public static func syncCategory(_ syncFrameIndex: Int) throws -> Int {
        guard syncFrameIndex >= 0, syncFrameIndex < DvdConstants.syncFramesPerBlock else {
            throw DiscError.encoding("Sync Frame 下标越界：\(syncFrameIndex)")
        }
        return DvdEccBlockBuilder.syncCategory(syncFrameIndex)
    }

    /// RS 码字余式是否全零（`parityBytes` = 2 / 10 / 16）。
    public static func hasZeroRemainder(_ codeword: [UInt8], parityBytes: Int) -> Bool {
        ReedSolomon.hasZeroRemainder(codeword[...], parityBytes: parityBytes)
    }

    /// 物理电平 → NRZI transition 位（1 = 翻转）。
    public static func transitionBits(from levels: [UInt8], initialLand: Bool = true) -> [UInt8] {
        var transitions = [UInt8](repeating: 0, count: levels.count)
        var previous = initialLand
        for index in 0..<levels.count {
            let current = levels[index] != 0
            transitions[index] = current == previous ? 0 : 1
            previous = current
        }
        return transitions
    }

    // MARK: - 内部

    private static func encodeRecordingFrames(
        _ frames: [UInt8],
        firstPsn: UInt32,
        initialBoundary: DvdModulationBoundary
    ) throws -> DvdPhysicalBlock {
        var levels = [UInt8](repeating: 0, count: DvdConstants.channelBitsPerBlock)
        let encoder = EfmPlusEncoder()
        var boundary = initialBoundary
        var outputOffset = 0
        for sector in 0..<DvdConstants.sectorsPerBlock {
            let frameOffset = sector * 13 * DvdConstants.eccColumns
            for row in 0..<13 {
                let rowBase = frameOffset + row * DvdConstants.eccColumns
                boundary = try encoder.encodeSyncFrame(
                    bytes: frames[rowBase..<(rowBase + 91)],
                    syncCategory: DvdEccBlockBuilder.firstSyncCategories[row],
                    input: boundary,
                    levels: &levels,
                    offset: outputOffset
                )
                outputOffset += DvdConstants.bitsPerSyncFrame
                boundary = try encoder.encodeSyncFrame(
                    bytes: frames[(rowBase + 91)..<(rowBase + DvdConstants.eccColumns)],
                    syncCategory: DvdEccBlockBuilder.secondSyncCategories[row],
                    input: boundary,
                    levels: &levels,
                    offset: outputOffset
                )
                outputOffset += DvdConstants.bitsPerSyncFrame
            }
        }
        precondition(outputOffset == DvdConstants.channelBitsPerBlock)
        return DvdPhysicalBlock(
            channelLevels: levels,
            firstPhysicalSectorNumber: firstPsn,
            finalBoundary: boundary
        )
    }

    private static func validateBlockInput(
        payloads: [UInt8],
        firstLba: Int,
        psnOffset: UInt32
    ) throws -> (firstPsn: UInt32, lastPsn: UInt32) {
        guard payloads.count == DvdConstants.payloadBytesPerBlock else {
            throw DiscError.encoding("一个 ECC Block 需要 \(DvdConstants.payloadBytesPerBlock) 字节 payload（当前 \(payloads.count)）")
        }
        let firstPsn = try physicalSectorNumber(lba: firstLba, psnOffset: psnOffset)
        guard firstPsn & 0xF == 0 else {
            throw DiscError.encoding("ECC Block 的首个 PSN 必须 16 扇区对齐（当前 0x\(String(firstPsn, radix: 16))）")
        }
        let lastPsn = firstPsn &+ UInt32(DvdConstants.sectorsPerBlock - 1)
        guard lastPsn <= 0x00FF_FFFF else {
            throw DiscError.encoding("ECC Block 超出 24 位 PSN 范围")
        }
        return (firstPsn, lastPsn)
    }
}
