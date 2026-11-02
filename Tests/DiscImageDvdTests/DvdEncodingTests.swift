import DiscImageCore
import XCTest

@testable import DiscImageDvd

/// 编码链不变量：Data Frame、ECC（PI/PO）、交织、EFMPlus/RLL、NRZI。
///
/// 都没有 golden file 可比（本机没有 .NET），验证的是数学不变量 + 源项目
/// `SelfTests.cs` 里同样断言过的性质。
final class DvdEncodingTests: XCTestCase {
    private let firstPsn: UInt32 = 0x030000

    // MARK: - Data Frame

    func testDataFrameLayout() throws {
        let payload = [UInt8](repeating: 0, count: DvdConstants.payloadBytesPerSector)
        let frame = try DvdChannelEncoder.dataFrame(payload: payload, physicalSectorNumber: firstPsn)
        XCTAssertEqual(frame.count, 2064)
        XCTAssertEqual(Array(frame[0..<4]), [0x00, 0x03, 0x00, 0x00])
        XCTAssertEqual(Array(frame[6..<12]), [0, 0, 0, 0, 0, 0])
        XCTAssertTrue(DvdChannelEncoder.hasZeroRemainder(Array(frame[0..<6]), parityBytes: 2))
        XCTAssertTrue(DvdDataFrameBuilder.hasValidEdc(frame))
    }

    func testScramblerXorRoundTrip() throws {
        let payload = [UInt8](repeating: 0, count: DvdConstants.payloadBytesPerSector)
        let plain = try DvdChannelEncoder.dataFrame(payload: payload, physicalSectorNumber: firstPsn)
        var scrambled = try DvdChannelEncoder.scrambledFrame(payload: payload, physicalSectorNumber: firstPsn)
        XCTAssertNotEqual(Array(scrambled[12..<2060]), Array(plain[12..<2060]), "扰码必须改变 payload")
        DvdDataFrameBuilder.scrambleMainData(&scrambled, physicalSectorNumber: firstPsn)
        XCTAssertEqual(scrambled, plain, "扰码器 XOR 往返")
    }

    func testScramblerMaskDependsOnBlockIndex() {
        let maskA = DvdDataFrameBuilder.payloadScramblerMask(physicalSectorNumber: 0x030000)
        let maskB = DvdDataFrameBuilder.payloadScramblerMask(physicalSectorNumber: 0x030010)
        XCTAssertEqual(maskA.count, 2048)
        XCTAssertNotEqual(maskA, maskB)
        // 同一个 16 扇区 Block 内掩码相同（只有 (PSN>>4)&0xF 参与选择）。
        XCTAssertEqual(maskA, DvdDataFrameBuilder.payloadScramblerMask(physicalSectorNumber: 0x03000F))
    }

    // MARK: - ECC

    func testEccZeroRemainders() throws {
        let payloads = [UInt8](repeating: 0, count: DvdConstants.payloadBytesPerBlock)
        let ecc = try DvdChannelEncoder.eccBytes(payloads: payloads, firstLba: 0)
        XCTAssertEqual(ecc.count, DvdConstants.eccRows * DvdConstants.eccColumns)

        for row in 0..<DvdConstants.eccRows {
            let base = row * DvdConstants.eccColumns
            XCTAssertTrue(
                DvdChannelEncoder.hasZeroRemainder(Array(ecc[base..<(base + DvdConstants.eccColumns)]), parityBytes: 10),
                "PI 第 \(row) 行余式不为零"
            )
        }

        var column = [UInt8](repeating: 0, count: DvdConstants.eccRows)
        for columnIndex in 0..<DvdConstants.dataColumns {
            for row in 0..<DvdConstants.eccRows {
                column[row] = ecc[row * DvdConstants.eccColumns + columnIndex]
            }
            XCTAssertTrue(
                DvdChannelEncoder.hasZeroRemainder(column, parityBytes: 16),
                "PO 第 \(columnIndex) 列余式不为零"
            )
        }
    }

    func testEccZeroRemaindersSurviveRandomPayload() throws {
        var generator = SystemRandomNumberGenerator()
        let payloads = (0..<DvdConstants.payloadBytesPerBlock).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let ecc = try DvdChannelEncoder.eccBytes(payloads: payloads, firstLba: 16)
        for row in 0..<DvdConstants.eccRows {
            let base = row * DvdConstants.eccColumns
            XCTAssertTrue(
                DvdChannelEncoder.hasZeroRemainder(Array(ecc[base..<(base + DvdConstants.eccColumns)]), parityBytes: 10)
            )
        }
        var column = [UInt8](repeating: 0, count: DvdConstants.eccRows)
        for columnIndex in 0..<DvdConstants.dataColumns {
            for row in 0..<DvdConstants.eccRows {
                column[row] = ecc[row * DvdConstants.eccColumns + columnIndex]
            }
            XCTAssertTrue(DvdChannelEncoder.hasZeroRemainder(column, parityBytes: 16))
        }
    }

    func testIncrementalEccMatchesFullRebuild() throws {
        var payloads = [UInt8](repeating: 0, count: DvdConstants.payloadBytesPerBlock)
        for index in payloads.indices {
            payloads[index] = UInt8(truncatingIfNeeded: index &* 37 &+ 11)
        }
        let frames = try DvdChannelEncoder.recordingFrames(payloads: payloads, firstLba: 0)

        var updated = payloads
        updated[17] = 0x5A
        updated[7 * 2048 + 991] = 0xC3
        updated[updated.count - 1] = 0x7E
        let incremental = try DvdChannelEncoder.updatedRecordingFrames(
            currentPayloads: payloads,
            updatedPayloads: updated,
            currentRecordingFrames: frames,
            firstLba: 0
        )
        let rebuilt = try DvdChannelEncoder.recordingFrames(payloads: updated, firstLba: 0)
        XCTAssertEqual(incremental, rebuilt, "增量重建必须与完整重建逐字节一致")

        // 多点随机改动，覆盖多行/多列的 PO、PI 交叉依赖。
        var generator = SystemRandomNumberGenerator()
        var mutated = payloads
        for _ in 0..<64 {
            let index = Int.random(in: 0..<mutated.count, using: &generator)
            mutated[index] ^= UInt8.random(in: 1...255, using: &generator)
        }
        let incrementalRandom = try DvdChannelEncoder.updatedRecordingFrames(
            currentPayloads: payloads,
            updatedPayloads: mutated,
            currentRecordingFrames: frames,
            firstLba: 0
        )
        XCTAssertEqual(incrementalRandom, try DvdChannelEncoder.recordingFrames(payloads: mutated, firstLba: 0))
    }

    func testPayloadRecordingFrameMapping() throws {
        XCTAssertEqual(DvdEccBlockBuilder.payloadDirectChannelOffset(0), 224)
        XCTAssertEqual(try DvdChannelEncoder.payloadChannelOffset(0), 232)
        var previous = -1
        var offsets = Set<Int>()
        for payloadIndex in 0..<DvdConstants.payloadBytesPerBlock {
            let offset = DvdEccBlockBuilder.payloadDirectChannelOffset(payloadIndex)
            XCTAssertGreaterThan(offset, previous, "payload 码字偏移必须单调递增")
            XCTAssertGreaterThanOrEqual(offset, 32)
            XCTAssertLessThanOrEqual(offset + 16, DvdConstants.channelBitsPerBlock)
            previous = offset
            offsets.insert(offset)
        }
        XCTAssertEqual(offsets.count, DvdConstants.payloadBytesPerBlock)
    }

    func testSyncCategories() {
        XCTAssertEqual(DvdEccBlockBuilder.syncCategory(0), 0)
        XCTAssertEqual(DvdEccBlockBuilder.syncCategory(1), 5)
        XCTAssertEqual(DvdEccBlockBuilder.syncCategory(2), 1)
        XCTAssertEqual(DvdEccBlockBuilder.syncCategory(24), 4)
        XCTAssertEqual(DvdEccBlockBuilder.syncCategory(25), 7)
        XCTAssertEqual(DvdEccBlockBuilder.syncCategory(26), 0)
    }

    // MARK: - EFMPlus / NRZI

    func testPhysicalBlockInvariants() throws {
        let payloads = [UInt8](repeating: 0, count: DvdConstants.payloadBytesPerBlock)
        let block = try DvdChannelEncoder.encodeBlock(payloads: payloads, firstLba: 0)
        XCTAssertEqual(block.channelLevels.count, DvdConstants.channelBitsPerBlock)
        XCTAssertEqual(block.channelLevels.count, 619_008)
        XCTAssertEqual(block.firstPhysicalSectorNumber, 0x030000)
        XCTAssertTrue(block.channelLevels.allSatisfy { $0 == 0 || $0 == 1 }, "电平必须是 0/1")

        let again = try DvdChannelEncoder.encodeBlock(payloads: payloads, firstLba: 0)
        XCTAssertEqual(block.channelLevels, again.channelLevels, "调制必须确定性")
        XCTAssertEqual(block.finalBoundary, again.finalBoundary)

        assertRLL(block.channelLevels, initialLand: true)
    }

    func testPhysicalBlockAllWhitePayload() throws {
        let payloads = [UInt8](repeating: DvdConstants.whiteScrambledByte, count: DvdConstants.payloadBytesPerBlock)
        let block = try DvdChannelEncoder.encodeBlock(payloads: payloads, firstLba: 16)
        XCTAssertEqual(block.firstPhysicalSectorNumber, 0x030010)
        assertRLL(block.channelLevels, initialLand: true)
        // 白纹理（0x92）与黑纹理（0xA5）必须产生不同的电平图样。
        let blackPayloads = [UInt8](repeating: DvdConstants.blackScrambledByte, count: DvdConstants.payloadBytesPerBlock)
        let blackBlock = try DvdChannelEncoder.encodeBlock(payloads: blackPayloads, firstLba: 16)
        XCTAssertNotEqual(block.channelLevels, blackBlock.channelLevels)
        let landCount = block.channelLevels.reduce(0) { $0 + Int($1) }
        XCTAssertGreaterThan(landCount, 0)
        XCTAssertLessThan(landCount, DvdConstants.channelBitsPerBlock)
    }

    func testPhysicalBlockRespectsEntryBoundary() throws {
        let payloads = [UInt8](repeating: 0x92, count: DvdConstants.payloadBytesPerBlock)
        for state in 1...4 {
            for land in [true, false] {
                let boundary = DvdModulationBoundary(state: state, dsv: land ? 7 : -7, isLand: land)
                let block = try DvdChannelEncoder.encodeBlock(
                    payloads: payloads,
                    firstLba: 0,
                    initialBoundary: boundary
                )
                XCTAssertEqual(block.channelLevels.count, DvdConstants.channelBitsPerBlock)
                assertRLL(block.channelLevels, initialLand: land)
            }
        }
    }

    func testRejectsMisalignedBlock() {
        let payloads = [UInt8](repeating: 0, count: DvdConstants.payloadBytesPerBlock)
        XCTAssertThrowsError(try DvdChannelEncoder.encodeBlock(payloads: payloads, firstLba: 1))
        XCTAssertThrowsError(try DvdChannelEncoder.encodeBlock(payloads: payloads, firstLba: 0, psnOffset: 1))
    }

    func testNrziLevelsAndDsvMatchBoundary() throws {
        let payloads = [UInt8](repeating: DvdConstants.whiteScrambledByte, count: DvdConstants.payloadBytesPerBlock)
        let block = try DvdChannelEncoder.encodeBlock(payloads: payloads, firstLba: 0)

        XCTAssertEqual(block.channelLevels.count / DvdConstants.sectorsPerBlock, 38_688)
        XCTAssertEqual(block.channelLevels.count, 619_008)

        // NRZI：transition 位必须与电平翻转一一对应；电平累加必须等于出口 DSV。
        let transitions = DvdChannelEncoder.transitionBits(from: block.channelLevels, initialLand: true)
        XCTAssertEqual(transitions.count, block.channelLevels.count)
        var previousLevel = true
        var transitionCount = 0
        var dsv = 0
        for index in 0..<block.channelLevels.count {
            let level = block.channelLevels[index] != 0
            XCTAssertEqual(
                transitions[index] == 1,
                level != previousLevel,
                "transition 位与电平变化不一致 @\(index)"
            )
            if transitions[index] == 1 { transitionCount += 1 }
            dsv += level ? 1 : -1
            previousLevel = level
        }
        XCTAssertEqual(dsv, block.finalBoundary.dsv, "DSV 必须等于电平累加")
        XCTAssertEqual(block.finalBoundary.isLand, block.channelLevels.last != 0)
        XCTAssertGreaterThan(transitionCount, 0)
        XCTAssertEqual(transitionCount % 2 == 0, block.finalBoundary.isLand, "从 land 起，翻转次数决定收尾电平")
    }

    func testBlockAssemblyConstants() throws {
        XCTAssertEqual(DvdConstants.sectorsPerBlock, 16)
        // 每扇区 38688 = 13 × 2 × (32 + 1456)
        XCTAssertEqual(DvdConstants.channelBitsPerSector, 13 * 2 * (32 + 1456))
        XCTAssertEqual(DvdConstants.channelBitsPerBlock, 16 * 38_688)
        XCTAssertEqual(DvdConstants.channelBitsPerBlock, 619_008)
        XCTAssertEqual(DvdConstants.channelBitsPerBlock / DvdConstants.sectorsPerBlock, 38_688)
        XCTAssertEqual(DvdConstants.syncFramesPerSector, 26)
        XCTAssertEqual(DvdConstants.syncFramesPerBlock, 416)
        XCTAssertEqual(DvdConstants.bytesPerSyncFrame, 91)
        XCTAssertEqual(DvdConstants.bitsPerSyncFrame, 1488)
        XCTAssertEqual(DvdConstants.syncFramesPerBlock * DvdConstants.bitsPerSyncFrame, DvdConstants.channelBitsPerBlock)
        XCTAssertEqual(DvdConstants.payloadBytesPerBlock, 16 * 2048)

        XCTAssertEqual(try DvdChannelEncoder.physicalSectorNumber(lba: 0), 0x30000)
        XCTAssertEqual(try DvdChannelEncoder.physicalSectorNumber(lba: 16), 0x30010)
        XCTAssertEqual(try DvdChannelEncoder.physicalSectorNumber(lba: 2_295_103), 0x30000 + 2_295_103)
    }

    // MARK: - RLL 校验

    /// 与源项目 `SelfTests.ValidateDataRll` 相同的口径：跳过每个 Sync Frame 的 32 位 SYNC，
    /// 检查 transition 之间的零游程落在 2…10（即 3T–11T）。
    private func assertRLL(_ levels: [UInt8], initialLand: Bool, file: StaticString = #filePath, line: UInt = #line) {
        var previous = initialLand
        var nrz = [UInt8](repeating: 0, count: DvdConstants.bitsPerSyncFrame)
        var frameOffset = 0
        while frameOffset < levels.count {
            for index in 0..<DvdConstants.bitsPerSyncFrame {
                let current = levels[frameOffset + index] != 0
                nrz[index] = current == previous ? 0 : 1
                previous = current
            }
            var zeroRun = 0
            for index in 32..<DvdConstants.bitsPerSyncFrame {
                if nrz[index] == 0 {
                    zeroRun += 1
                } else {
                    XCTAssertTrue(
                        zeroRun >= 2 && zeroRun <= 10,
                        "RLL 零游程 \(zeroRun) 出现在通道偏移 \(frameOffset + index)",
                        file: file,
                        line: line
                    )
                    zeroRun = 0
                }
            }
            frameOffset += DvdConstants.bitsPerSyncFrame
        }
    }
}
