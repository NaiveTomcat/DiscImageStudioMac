import DiscImageCore
import Foundation
import XCTest

@testable import DiscImageCd

/// 优化后的快路径与原先逐字节实现的对拍。
///
/// CD 优化的硬约束是**输出逐字节不变**，而"快"来自三处等价改写：
/// 预计算亮度表、影调查找表、并行分块 + 批量交织。这里逐个把「快路径」钉回
/// 「参考实现」（`RasterImage.luminance` / `CdToneMapping.map` / `ToneDither.phase`），
/// 任何一步改错都会在这里失败，而不是等到参考产物 sha256 对不上。
final class CdFastPathEquivalenceTests: XCTestCase {

    // MARK: - 抖动相位

    func testDitherPhaseMatchesCoreImplementation() {
        var indices: [Int64] = [0, 1, 2, 23, 24, 25, 1_000, 65_535, 65_536]
        indices.append(contentsOf: stride(from: Int64(0), to: 5_000, by: 37))
        indices.append(contentsOf: [846_364_847, 359_849 * 2_352 - 1])
        for index in indices {
            XCTAssertEqual(
                cdDitherPhase(index).bitPattern,
                ToneDither.phase(index).bitPattern,
                "相位在 sampleIndex \(index) 处不一致"
            )
        }
    }

    // MARK: - 影调查找表

    private func tones() -> [(String, ToneProfile)] {
        [
            ("legacyBinary", ToneProfile.legacyBinary),
            ("default", ToneProfile.default),
            ("dither1", ToneProfile(ditherStrength: 1, levels: 2, brightness: 0)),
            ("fourLevelFlat", ToneProfile(ditherStrength: 0, levels: 4, brightness: 0)),
            ("fourLevelDither", ToneProfile(ditherStrength: 0.6, levels: 4, brightness: 0)),
            ("fourLevelGamma", ToneProfile(ditherStrength: 1, levels: 4, brightness: 0, srgbLinearization: 1)),
            ("bright", ToneProfile(ditherStrength: 0.75, levels: 2, brightness: 40)),
            ("dark", ToneProfile(ditherStrength: 0.75, levels: 2, brightness: -40)),
            ("gamma", ToneProfile(ditherStrength: 0.3, levels: 2, brightness: 0, srgbLinearization: 0.5)),
        ]
    }

    func testToneLUTMatchesCdToneMapping() {
        var indices: [Int64] = [0, 1, 2, 23, 24, 25, 1_023, 65_535]
        indices.append(contentsOf: stride(from: Int64(0), to: 900, by: 13))
        indices.append(contentsOf: [846_364_847, 846_364_846])

        for (label, tone) in tones() {
            let normalized = tone.normalized()
            let lut = CdToneLUT(tone: normalized)
            for gray in stride(from: 0, through: 255, by: 7) {
                for index in indices {
                    XCTAssertEqual(
                        lut.byte(gray: UInt8(gray), sampleIndex: index),
                        CdToneMapping.map(gray: UInt8(gray), tone: normalized, sampleIndex: index),
                        "\(label) 灰度 \(gray) sampleIndex \(index)"
                    )
                }
            }
        }
    }

    // MARK: - 亮度表

    func testLuminanceTableMatchesDirectRasterSampling() {
        let tonedImage = CdTestSupport.testImage(width: 48, height: 48)
        let binaryImage = CdTestSupport.binaryImage(width: 32, height: 32)
        let parameters = CdTestSupport.parameters(sectors: 40)

        for image in [tonedImage, binaryImage] {
            let fast = CdImageSampler(image: image, parameters: parameters)
            let reference = CdImageSampler(image: image, parameters: parameters, luminanceTableByteBudget: 0)
            XCTAssertTrue(fast.usesLuminanceTable)
            XCTAssertFalse(reference.usesLuminanceTable)
            XCTAssertEqual(fast.isNearestNeighbour, image.isOpaqueBinaryGrayscale)

            for step in 0...2_000 {
                let byte = parameters.totalBytes * step / 2_000
                XCTAssertEqual(
                    fast.gray(atByte: byte),
                    reference.gray(atByte: byte),
                    "亮度表路径与现算路径在字节 \(byte) 处不一致"
                )
            }
            // 越界与端点也要一致。
            for byte in [-5, 0, 1, parameters.totalBytes - 1, parameters.totalBytes, parameters.totalBytes + 99] {
                XCTAssertEqual(fast.gray(atByte: byte), reference.gray(atByte: byte), "字节 \(byte)")
            }
        }
    }

    // MARK: - 整块填充

    func testBlockSamplerMatchesPerByteMapping() {
        let cases: [(String, RasterImage, ToneProfile)] = [
            ("photo/legacy", CdTestSupport.testImage(width: 40, height: 40), .legacyBinary),
            ("photo/dither", CdTestSupport.testImage(width: 40, height: 40), .default),
            ("photo/four", CdTestSupport.testImage(width: 40, height: 40),
             ToneProfile(ditherStrength: 0.8, levels: 4, brightness: 5, srgbLinearization: 0.5)),
            ("binary/dither", CdTestSupport.binaryImage(width: 24, height: 24), .default),
        ]
        let parameters = CdTestSupport.parameters(sectors: 3)

        for (label, image, tone) in cases {
            let sampler = CdImageSampler(image: image, parameters: parameters)
            let blockSampler = CdBlockSampler(sampler: sampler, tone: tone)
            var produced = [UInt8](repeating: 0, count: parameters.totalBytes)
            produced.withUnsafeMutableBufferPointer { pointer in
                blockSampler.fill(start: 0, count: parameters.totalBytes, into: pointer.baseAddress!)
            }

            for byte in 0..<parameters.totalBytes {
                let expected = CdToneMapping.map(
                    gray: sampler.gray(atByte: byte),
                    tone: tone,
                    sampleIndex: Int64(byte)
                )
                XCTAssertEqual(produced[byte], expected, "\(label) 字节 \(byte)")
            }
        }
    }

    func testBlockSamplerHandlesMisalignedBlocks() throws {
        // 分块边界不必落在帧/扇区边界上：逐块填充后再拼接必须等于一次填完。
        let parameters = CdTestSupport.parameters(sectors: 2)
        let sampler = CdImageSampler(image: CdTestSupport.testImage(width: 32, height: 32), parameters: parameters)
        let blockSampler = CdBlockSampler(sampler: sampler, tone: .default)
        let total = parameters.totalBytes

        var reference = [UInt8](repeating: 0, count: total)
        reference.withUnsafeMutableBufferPointer { pointer in
            blockSampler.fill(start: 0, count: total, into: pointer.baseAddress!)
        }

        // 故意用 1_000 字节这种非 24 倍数的块大小。
        var chunked = [UInt8](repeating: 0, count: total)
        var start = 0
        while start < total {
            let count = min(1_000, total - start)
            chunked.withUnsafeMutableBufferPointer { pointer in
                blockSampler.fill(start: start, count: count, into: pointer.baseAddress!.advanced(by: start))
            }
            start += count
        }
        XCTAssertEqual(chunked, reference)
    }

    // MARK: - 交织器批量入口

    func testBulkAddMatchesSingleByteAdd() throws {
        let totalBytes = 3 * CdDiscParameters.bytesPerSector + 111   // 故意不是帧倍数
        func values(count: Int) -> [UInt8] {
            (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ 7) }
        }

        for byteOrder in [CdAudioByteOrder.bigEndian, .littleEndian] {
            let singleSink = DataSequentialSink()
            let bulkSink = DataSequentialSink()
            let single = CddaInterleaver(sink: singleSink, byteOrder: byteOrder)
            let bulk = CddaInterleaver(sink: bulkSink, byteOrder: byteOrder)

            for value in values(count: totalBytes) {
                try single.add(value)
            }
            try single.flush()

            let source = values(count: totalBytes)
            var offset = 0
            for size in [1, 5, 24, 2352, 100, totalBytes] where offset < totalBytes {
                let count = min(size, totalBytes - offset)
                source.withUnsafeBufferPointer { pointer in
                    try? bulk.add(UnsafeBufferPointer(rebasing: pointer[offset..<(offset + count)]))
                }
                offset += count
            }
            if offset < totalBytes {
                source.withUnsafeBufferPointer { pointer in
                    try? bulk.add(UnsafeBufferPointer(rebasing: pointer[offset..<totalBytes]))
                }
            }
            try bulk.flush()

            XCTAssertEqual(bulkSink.bytes.count, singleSink.bytes.count, "\(byteOrder) 长度")
            XCTAssertEqual(bulkSink.bytes, singleSink.bytes, "\(byteOrder) 内容")
            XCTAssertEqual(bulk.bytesWritten, single.bytesWritten)
        }
    }

    /// 大块一次喂入（并行路径的真实形态：每块 32 个扇区）。
    func testBulkAddLargeBlocksMatchesReferenceInterleaveTable() throws {
        let totalBytes = 8 * CdDiscParameters.bytesPerSector
        let sink = DataSequentialSink()
        let interleaver = CddaInterleaver(sink: sink, byteOrder: .bigEndian)
        let block = CdAudioTrackGenerator.blockBytes

        let values = (0..<totalBytes).map { UInt8(truncatingIfNeeded: $0) }
        var offset = 0
        while offset < totalBytes {
            let count = min(block, totalBytes - offset)
            values.withUnsafeBufferPointer { pointer in
                try? interleaver.add(UnsafeBufferPointer(rebasing: pointer[offset..<(offset + count)]))
            }
            offset += count
        }
        try interleaver.flush()

        XCTAssertEqual(sink.bytes.count, totalBytes)
        for logical in 0..<totalBytes {
            let fileIndex = CddaInterleaveTable.fileIndex(forLogicalByte: logical)
            guard fileIndex < totalBytes else { continue }
            XCTAssertEqual(sink.bytes[fileIndex], UInt8(truncatingIfNeeded: logical), "逻辑字节 \(logical)")
        }
        XCTAssertEqual(
            CddaInterleaveTable.droppedTailByteCount(totalBytes: totalBytes),
            1_332
        )
    }
}
