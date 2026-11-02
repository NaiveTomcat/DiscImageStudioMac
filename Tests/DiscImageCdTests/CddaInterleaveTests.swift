import DiscImageCore
import Foundation
import XCTest

@testable import DiscImageCd

/// 112 帧环形延迟交织（task-2 第 3 条的硬断言）：
/// 24 字节/帧、偏移 72…2592、逻辑字节 `i` 落在 `i + offset(i % 24)`、
/// 尾部丢弃 1318–1332 字节。**不涉及** CIRC / EFM。
final class CddaInterleaveTests: XCTestCase {

    /// 源表逐项照抄（`CddaInterleaveTable.cs`，本身移植自 cdimage 的 converter.cpp）。
    private let expectedDelays = [
        -72, -143, -256, -327, -440, -511, -646, -717, -830, -901, -1014, -1085,
        -1556, -1627, -1740, -1811, -1924, -1995, -2130, -2201, -2314, -2385, -2498, -2569,
    ]

    private let expectedFileOffsets = [
        2592, 2520, 2406, 2334, 2220, 2148, 2012, 1940, 1826, 1754, 1640, 1568,
        1096, 1024, 910, 838, 724, 652, 516, 444, 330, 258, 144, 72,
    ]

    func testTableConstants() {
        XCTAssertEqual(CddaInterleaveTable.depth, 4)
        XCTAssertEqual(CddaInterleaveTable.bytesPerFrame, 24)
        XCTAssertEqual(CddaInterleaveTable.framesPerCycle, 112)   // 28 × 4
        XCTAssertEqual(CddaInterleaveTable.cycleBytes, 2_688)     // 112 × 24
    }

    func testDelayAndOffsetTablesMatchSource() {
        XCTAssertEqual(CddaInterleaveTable.delays, expectedDelays)
        XCTAssertEqual(CddaInterleaveTable.fileOffsets, expectedFileOffsets)
        for position in 0..<24 {
            XCTAssertEqual(CddaInterleaveTable.delay(for: position), expectedDelays[position])
            XCTAssertEqual(CddaInterleaveTable.fileOffset(for: position), expectedFileOffsets[position])
        }
        // 位置越界时按 24 取模（读回预览会传任意逻辑字节序号）。
        XCTAssertEqual(CddaInterleaveTable.fileOffset(for: 24), expectedFileOffsets[0])
        XCTAssertEqual(CddaInterleaveTable.fileOffset(for: 37), expectedFileOffsets[13])
    }

    func testOffsetsStayInsideHardRange() {
        XCTAssertEqual(CddaInterleaveTable.minimumFileOffset, 72)
        XCTAssertEqual(CddaInterleaveTable.maximumFileOffset, 2_592)
        for offset in CddaInterleaveTable.fileOffsets {
            XCTAssertTrue((72...2_592).contains(offset), "偏移 \(offset) 越界")
        }
    }

    func testFileOffsetUsesLogicalByteIndexModuloFrame() {
        for byte in 0..<1_000 {
            XCTAssertEqual(
                CddaInterleaveTable.fileOffset(forLogicalByte: byte),
                expectedFileOffsets[byte % 24],
                "逻辑字节 \(byte)"
            )
            XCTAssertEqual(
                CddaInterleaveTable.fileIndex(forLogicalByte: byte),
                byte + expectedFileOffsets[byte % 24]
            )
        }
    }

    /// 端到端：把「逻辑字节 i 的取值 = i & 0xFF」喂进交织器，逐项验证落点。
    func testLogicalByteLandsAtExpectedFileIndex() throws {
        let sectors = 8
        let totalBytes = sectors * CdDiscParameters.bytesPerSector
        let sink = DataSequentialSink()
        let interleaver = CddaInterleaver(sink: sink, byteOrder: .bigEndian)

        for index in 0..<totalBytes {
            try interleaver.add(UInt8(truncatingIfNeeded: index))
        }
        try interleaver.flush()

        XCTAssertEqual(sink.bytes.count, totalBytes)
        XCTAssertEqual(interleaver.bytesWritten, totalBytes)

        var checked = 0
        for logical in 0..<totalBytes {
            let fileIndex = CddaInterleaveTable.fileIndex(forLogicalByte: logical)
            guard fileIndex < totalBytes else { continue }
            XCTAssertEqual(
                sink.bytes[fileIndex],
                UInt8(truncatingIfNeeded: logical),
                "逻辑字节 \(logical) 应落在文件索引 \(fileIndex)"
            )
            checked += 1
        }
        let dropped = CddaInterleaveTable.droppedTailByteCount(totalBytes: totalBytes)
        XCTAssertEqual(checked, totalBytes - dropped)
        XCTAssertEqual(dropped, 1_332)
        XCTAssertTrue((1_318...1_332).contains(dropped), "尾部丢弃 \(dropped) 字节，超出 1318–1332")
    }

    func testTailDropIsWithinDocumentedRange() {
        // 源项目口径：整盘 1318–1332 字节，不到一个扇区。
        for sectors in [2, 3, 5, 8, 16, 98, 1_000] {
            let total = sectors * CdDiscParameters.bytesPerSector
            let dropped = CddaInterleaveTable.droppedTailByteCount(totalBytes: total)
            XCTAssertTrue((1_318...1_332).contains(dropped), "\(sectors) 扇区丢了 \(dropped) 字节")
            XCTAssertEqual(dropped, 1_332, "\(sectors) 扇区")
        }
        // 80 分钟整盘（359,849 扇区）同样落在范围内，且远小于一个扇区。
        let fullDisc = DiscPreset.cd80.sectors * CdDiscParameters.bytesPerSector
        let droppedOnFullDisc = CddaInterleaveTable.droppedTailByteCount(totalBytes: fullDisc)
        XCTAssertTrue((1_318...1_332).contains(droppedOnFullDisc))
        XCTAssertLessThan(droppedOnFullDisc, CdDiscParameters.bytesPerSector)
    }

    func testByteOrderSwapHappensAtSectorBoundary() throws {
        let totalBytes = 2 * CdDiscParameters.bytesPerSector
        let bigEndianSink = DataSequentialSink()
        let littleEndianSink = DataSequentialSink()
        let big = CddaInterleaver(sink: bigEndianSink, byteOrder: .bigEndian)
        let little = CddaInterleaver(sink: littleEndianSink, byteOrder: .littleEndian)

        for index in 0..<totalBytes {
            let value = UInt8(truncatingIfNeeded: index &* 37)
            try big.add(value)
            try little.add(value)
        }
        try big.flush()
        try little.flush()

        XCTAssertEqual(bigEndianSink.bytes.count, totalBytes)
        XCTAssertEqual(littleEndianSink.bytes.count, totalBytes)
        for index in 0..<totalBytes {
            XCTAssertEqual(
                littleEndianSink.bytes[index],
                bigEndianSink.bytes[index ^ 1],
                "小端输出应是扇区内相邻字节交换（索引 \(index)）"
            )
        }
    }

    func testFlushPadsPartialSectorWithZeros() throws {
        let sink = DataSequentialSink()
        let interleaver = CddaInterleaver(sink: sink, byteOrder: .bigEndian)
        // 1.5 个扇区：多少字节都会被凑成整帧（24 的倍数）。
        let bytes = CdDiscParameters.bytesPerSector + 1_200
        for index in 0..<bytes {
            try interleaver.add(UInt8(truncatingIfNeeded: index))
        }
        try interleaver.flush()

        XCTAssertEqual(sink.bytes.count, 2 * CdDiscParameters.bytesPerSector)
        XCTAssertEqual(interleaver.bytesWritten, 2 * CdDiscParameters.bytesPerSector)
        // 尾部补零：最后一个扇区里未被环形缓冲覆盖的位置是 0。
        let zeroCount = sink.bytes[(2 * CdDiscParameters.bytesPerSector - 64)...].filter { $0 == 0 }.count
        XCTAssertGreaterThan(zeroCount, 0)
    }
}
