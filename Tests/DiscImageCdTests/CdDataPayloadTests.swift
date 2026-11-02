import DiscImageCore
import Foundation
import XCTest

@testable import DiscImageCd

/// 数据盘 Mode 1 的 CD 侧补偿原语（task-2 第 5 条的 CD 部分）。
///
/// 布局（ISO9660 目录树、内外圈文件区）由工作包 A 的写入器负责，这里只验证
/// 绘图区的采样位置反查与 ECMA-130 扰码：
/// 这部分做好了，接线时就是「按布局逐扇区取 2048 字节」。
final class CdDataPayloadTests: XCTestCase {

    func testScrambleMaskMatchesEcm130AnnexB() {
        // x^15 + x + 1、种子 1、最低位先出的前 8 个字节。
        XCTAssertEqual(CdDataPayload.scrambleMask.count, CdDiscParameters.bytesPerSector - 12)
        XCTAssertEqual(Array(CdDataPayload.scrambleMask.prefix(8)), [1, 128, 0, 96, 0, 40, 0, 30])
        // 掩码里不应全是 0（那说明 LFSR 没跑起来）。
        XCTAssertGreaterThan(CdDataPayload.scrambleMask.filter { $0 != 0 }.count, 1_000)
    }

    func testPayloadOffsetsInSector() {
        XCTAssertEqual(CdDataPayload.payloadBytesPerSector, 2_048)
        XCTAssertEqual(CdDataPayload.payloadOffset, 16)
        XCTAssertEqual(CdDataPayload.scrambleIndex(forPayloadIndex: 0), 4)
        XCTAssertEqual(CdDataPayload.scrambleIndex(forPayloadIndex: 2_047), 2_051)
        XCTAssertLessThan(CdDataPayload.scrambleIndex(forPayloadIndex: 2_047), CdDataPayload.scrambleMask.count)
    }

    func testInverseOffsetsInvertTheInterleaveTable() {
        for position in 0..<CddaInterleaveTable.bytesPerFrame {
            let displacement = CddaInterleaveTable.fileOffset(for: position)
            let column = ((position + displacement) % 24 + 24) % 24
            XCTAssertEqual(CdDataPayload.inverseFileOffsets[column], -displacement)
        }
    }

    func testPhysicalByteInvertsTheInterleave() {
        // 物理位置 p（已做相邻字节交换）对应的逻辑字节是 p + inverse[p % 24]，
        // 于是「逻辑字节 + 它的文件偏移」应回到那个物理位置。
        for lba in [256, 1_000, 10_000, 100_000] {
            for payloadIndex in [0, 1, 2, 1_023, 2_046, 2_047] {
                let frameByte = (lba * CdDiscParameters.bytesPerSector + 16 + payloadIndex) ^ 1
                let physical = CdDataPayload.physicalByte(lba: lba, payloadIndex: payloadIndex)
                XCTAssertGreaterThanOrEqual(physical, 0, "lba \(lba) payload \(payloadIndex)")
                XCTAssertEqual(
                    physical + CddaInterleaveTable.fileOffset(forLogicalByte: physical),
                    frameByte,
                    "lba \(lba) payload \(payloadIndex)"
                )
            }
        }
    }

    func testAdjacentByteSwapIsAppliedToThePayloadPosition() {
        // 相邻字节交换（^1）让 payload 内的 0/1 两个位置互换物理奇偶。
        let even = CdDataPayload.physicalByte(lba: 10_000, payloadIndex: 0)
        let odd = CdDataPayload.physicalByte(lba: 10_000, payloadIndex: 1)
        XCTAssertNotEqual(even % 2, odd % 2)
    }

    func testDrawingPayloadIsPaletteBytesXorScrambleMask() {
        let parameters = CdDiscParameters(
            innerRadiusMm: 24.5,
            outerRadiusMm: 56.8,
            sectors: 200_000
        )
        let tone = ToneProfile(ditherStrength: 0.5, levels: 2, brightness: 0)
        let sampler = CdImageSampler(image: CdTestSupport.testImage(), parameters: parameters)
        let lba = 10_000

        let payload = CdDataPayload.drawingPayload(lba: lba, sampler: sampler, tone: tone)
        XCTAssertEqual(payload.count, 2_048)
        let palette = Set(CdToneMapping.twoLevelPalette)
        for index in 0..<2_048 {
            let unmasked = payload[index] ^ CdDataPayload.scrambleMask[CdDataPayload.scrambleIndex(forPayloadIndex: index)]
            XCTAssertTrue(palette.contains(unmasked), "payload \(index) 解扰后是 0x\(String(unmasked, radix: 16))")
        }
        // 扰码必须真的改了字节（否则补偿漏了）。
        let scrambledCount = (0..<2_048).filter {
            payload[$0] != (payload[$0] ^ CdDataPayload.scrambleMask[CdDataPayload.scrambleIndex(forPayloadIndex: $0)])
        }.count
        XCTAssertGreaterThan(scrambledCount, 1_500, "扰码应改动绝大多数 payload 字节，实际 \(scrambledCount)")
    }

    func testDrawingPayloadSamplesAtPhysicalPosition() {
        let parameters = CdDiscParameters(
            innerRadiusMm: 24.5,
            outerRadiusMm: 56.8,
            sectors: 200_000
        )
        let tone = ToneProfile(ditherStrength: 0.75, levels: 2, brightness: 0)
        let sampler = CdImageSampler(image: CdTestSupport.testImage(), parameters: parameters)
        let lba = 50_000
        let payload = CdDataPayload.drawingPayload(lba: lba, sampler: sampler, tone: tone)

        for index in [0, 1, 700, 2_047] {
            let physical = CdDataPayload.physicalByte(lba: lba, payloadIndex: index)
            let expected = sampler.paletteByte(atByte: physical, tone: tone)
                ^ CdDataPayload.scrambleMask[CdDataPayload.scrambleIndex(forPayloadIndex: index)]
            XCTAssertEqual(payload[index], expected, "payload \(index)")
        }
    }
}
