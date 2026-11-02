import DiscImageCore
import Foundation

/// 一个 ECC Block 的记录帧（208 × 182 字节）及其增量重建。
///
/// 与源项目 `DvdEccBlockEncoder.cs` 同构：
/// - 16 个扇区的 Data Frame 数据区铺成 192 × 172 的数据矩阵；
/// - PO 按列 RS(208,192) 补 16 行；
/// - PI 按行 RS(182,172) 补 10 列；
/// - 记录帧交织：数据行 `destination = source + source/12`，
///   PO 行 `destination = 13*(source-191) - 1`。
enum DvdEccBlockBuilder {
    /// 同一扇区内 13 行；奇偶帧的 SYNC 类别表（ECMA-267）。
    static let firstSyncCategories = [0, 1, 2, 3, 4, 1, 2, 3, 4, 1, 2, 3, 4]
    static let secondSyncCategories = [5, 5, 5, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7]

    // MARK: - 记录帧布局

    /// 把 ECC 矩阵的 (eccRow, eccColumn) 换算成记录帧（交织后）下标。
    static func recordingFrameIndex(eccRow: Int, eccColumn: Int) -> Int {
        precondition(eccRow >= 0 && eccRow < DvdConstants.eccRows)
        precondition(eccColumn >= 0 && eccColumn < DvdConstants.eccColumns)
        let recordingRow: Int
        if eccRow < DvdConstants.dataRows {
            recordingRow = eccRow + eccRow / 12
        } else {
            recordingRow = 13 * (eccRow - 191) - 1
        }
        return recordingRow * DvdConstants.eccColumns + eccColumn
    }

    /// payload 第 `payloadIndex` 字节在**记录帧**里的下标。
    static func payloadRecordingFrameIndex(_ payloadIndex: Int) -> Int {
        precondition(payloadIndex >= 0 && payloadIndex < DvdConstants.payloadBytesPerBlock)
        let sector = payloadIndex / DvdConstants.payloadBytesPerSector
        let frameIndex = 12 + (payloadIndex % DvdConstants.payloadBytesPerSector)
        let eccRow = sector * 12 + frameIndex / DvdConstants.dataColumns
        let eccColumn = frameIndex % DvdConstants.dataColumns
        return recordingFrameIndex(eccRow: eccRow, eccColumn: eccColumn)
    }

    /// payload 第 `payloadIndex` 字节的 16 位码字在 **ECC Block 通道位流**里的起始位置。
    ///
    /// 每个 Sync Frame = 32 bit SYNC + 91 × 16 bit；payload 字节落在去掉 SYNC 后的
    /// 第 `byteInSyncFrame` 个码字。绘制时取 `+8` 作为码字中心。
    static func payloadDirectChannelOffset(_ payloadIndex: Int) -> Int {
        let recordingIndex = payloadRecordingFrameIndex(payloadIndex)
        let syncFrame = recordingIndex / DvdConstants.bytesPerSyncFrame
        let byteInSyncFrame = recordingIndex % DvdConstants.bytesPerSyncFrame
        return syncFrame * DvdConstants.bitsPerSyncFrame
            + DvdConstants.syncCodeBits
            + byteInSyncFrame * 16
    }

    /// block 内第 `syncFrameIndex` 个 Sync Frame 的 SYNC 类别（0…7）。
    static func syncCategory(_ syncFrameIndex: Int) -> Int {
        precondition(syncFrameIndex >= 0 && syncFrameIndex < DvdConstants.syncFramesPerBlock)
        let withinSector = syncFrameIndex % DvdConstants.syncFramesPerSector
        let row = withinSector / 2
        return (withinSector & 1) == 0
            ? firstSyncCategories[row]
            : secondSyncCategories[row]
    }

    // MARK: - 矩阵组装

    /// 16 扇区 payload → ECC 矩阵（208×182，尚未交织）。
    static func buildEccBytes(payloads: [UInt8], firstPsn: UInt32) -> [UInt8] {
        precondition(payloads.count == DvdConstants.payloadBytesPerBlock)
        var ecc = [UInt8](repeating: 0, count: DvdConstants.eccRows * DvdConstants.eccColumns)
        for sector in 0..<DvdConstants.sectorsPerBlock {
            let offset = sector * DvdConstants.payloadBytesPerSector
            let frame = DvdDataFrameBuilder.buildScrambledFrame(
                payload: payloads[offset..<(offset + DvdConstants.payloadBytesPerSector)],
                physicalSectorNumber: firstPsn + UInt32(sector)
            )
            for row in 0..<12 {
                let source = row * DvdConstants.dataColumns
                let destination = (sector * 12 + row) * DvdConstants.eccColumns
                ecc.replaceSubrange(
                    destination..<(destination + DvdConstants.dataColumns),
                    with: frame[source..<(source + DvdConstants.dataColumns)]
                )
            }
        }

        // PO：172 列，每列 192 个数据字节 + 16 个校验字节。
        var column = [UInt8](repeating: 0, count: DvdConstants.dataRows)
        for columnIndex in 0..<DvdConstants.dataColumns {
            for row in 0..<DvdConstants.dataRows {
                column[row] = ecc[row * DvdConstants.eccColumns + columnIndex]
            }
            let parity = ReedSolomon.poParity(column[...])
            for row in 0..<DvdConstants.poParityBytes {
                ecc[(DvdConstants.dataRows + row) * DvdConstants.eccColumns + columnIndex] = parity[row]
            }
        }

        // PI：208 行，每行 172 个数据字节 + 10 个校验字节。
        for row in 0..<DvdConstants.eccRows {
            let base = row * DvdConstants.eccColumns
            let parity = ReedSolomon.piParity(ecc[base..<(base + DvdConstants.dataColumns)])
            for index in 0..<DvdConstants.piParityBytes {
                ecc[base + DvdConstants.dataColumns + index] = parity[index]
            }
        }

        return ecc
    }

    /// ECC 矩阵交错成 208 × 182 的记录帧。
    static func interleaveRecordingFrames(_ ecc: [UInt8]) -> [UInt8] {
        precondition(ecc.count == DvdConstants.eccRows * DvdConstants.eccColumns)
        var frames = [UInt8](repeating: 0, count: ecc.count)
        for sourceRow in 0..<DvdConstants.dataRows {
            let destinationRow = sourceRow + sourceRow / 12
            let source = sourceRow * DvdConstants.eccColumns
            let destination = destinationRow * DvdConstants.eccColumns
            frames.replaceSubrange(
                destination..<(destination + DvdConstants.eccColumns),
                with: ecc[source..<(source + DvdConstants.eccColumns)]
            )
        }
        for sourceRow in DvdConstants.dataRows..<DvdConstants.eccRows {
            let destinationRow = 13 * (sourceRow - 191) - 1
            let source = sourceRow * DvdConstants.eccColumns
            let destination = destinationRow * DvdConstants.eccColumns
            frames.replaceSubrange(
                destination..<(destination + DvdConstants.eccColumns),
                with: ecc[source..<(source + DvdConstants.eccColumns)]
            )
        }
        return frames
    }

    /// payload → 记录帧（完整重建）。
    static func buildRecordingFrames(payloads: [UInt8], firstPsn: UInt32) -> [UInt8] {
        interleaveRecordingFrames(buildEccBytes(payloads: payloads, firstPsn: firstPsn))
    }

    /// 增量重建：只重算被改动的行/列校验，结果必须与完整重建逐字节一致。
    ///
    /// 交互式「改几个字节看效果」时用这条路径，避免每改一个字节重算整个 Block。
    static func updateRecordingFrames(
        currentPayloads: [UInt8],
        updatedPayloads: [UInt8],
        currentRecordingFrames: [UInt8],
        firstPsn: UInt32
    ) -> [UInt8] {
        precondition(currentPayloads.count == DvdConstants.payloadBytesPerBlock)
        precondition(updatedPayloads.count == DvdConstants.payloadBytesPerBlock)
        precondition(currentRecordingFrames.count == DvdConstants.eccRows * DvdConstants.eccColumns)

        var frames = currentRecordingFrames
        var changedColumns = [Bool](repeating: false, count: DvdConstants.dataColumns)
        var changedRows = [Bool](repeating: false, count: DvdConstants.eccRows)

        for sector in 0..<DvdConstants.sectorsPerBlock {
            let payloadOffset = sector * DvdConstants.payloadBytesPerSector
            let range = payloadOffset..<(payloadOffset + DvdConstants.payloadBytesPerSector)
            if updatedPayloads[range] == currentPayloads[range] {
                continue
            }

            let dataFrame = DvdDataFrameBuilder.buildScrambledFrame(
                payload: updatedPayloads[range],
                physicalSectorNumber: firstPsn + UInt32(sector)
            )
            for row in 0..<12 {
                let eccRow = sector * 12 + row
                let recordingOffset = recordingFrameIndex(eccRow: eccRow, eccColumn: 0)
                let source = row * DvdConstants.dataColumns
                var rowChanged = false
                for column in 0..<DvdConstants.dataColumns {
                    if dataFrame[source + column] != frames[recordingOffset + column] {
                        changedColumns[column] = true
                        rowChanged = true
                    }
                }
                if rowChanged {
                    frames.replaceSubrange(
                        recordingOffset..<(recordingOffset + DvdConstants.dataColumns),
                        with: dataFrame[source..<(source + DvdConstants.dataColumns)]
                    )
                    changedRows[eccRow] = true
                }
            }
        }

        // PO：只重算被改动过的列。
        var columnBytes = [UInt8](repeating: 0, count: DvdConstants.dataRows)
        for column in 0..<DvdConstants.dataColumns where changedColumns[column] {
            for row in 0..<DvdConstants.dataRows {
                columnBytes[row] = frames[recordingFrameIndex(eccRow: row, eccColumn: column)]
            }
            let parity = ReedSolomon.poParity(columnBytes[...])
            for parityRow in 0..<DvdConstants.poParityBytes {
                let eccRow = DvdConstants.dataRows + parityRow
                let recordingIndex = recordingFrameIndex(eccRow: eccRow, eccColumn: column)
                if frames[recordingIndex] != parity[parityRow] {
                    frames[recordingIndex] = parity[parityRow]
                    changedRows[eccRow] = true
                }
            }
        }

        // PI：只重算被改动过的行。
        for row in 0..<DvdConstants.eccRows where changedRows[row] {
            let recordingOffset = recordingFrameIndex(eccRow: row, eccColumn: 0)
            let parity = ReedSolomon.piParity(
                frames[recordingOffset..<(recordingOffset + DvdConstants.dataColumns)]
            )
            for index in 0..<DvdConstants.piParityBytes {
                frames[recordingOffset + DvdConstants.dataColumns + index] = parity[index]
            }
        }

        return frames
    }
}
