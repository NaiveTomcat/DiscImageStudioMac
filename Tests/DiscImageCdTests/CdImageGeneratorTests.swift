import DiscImageCore
import Foundation
import XCTest

@testable import DiscImageCd

/// CD 引擎公开入口的端到端测试（task-2 第 6 条 + 验收项）。
///
/// 全部用 8 扇区的小几何：WAV 19 kB 级别，跑得快，也不占磁盘。
final class CdImageGeneratorTests: XCTestCase {

    private let parameters = CdTestSupport.parameters()
    private var totalBytes: Int { parameters.totalBytes }

    private func request(
        format: GenerationOutputFormat,
        tone: ToneProfile = ToneProfile.legacyBinary,
        image: RasterImage? = nil,
        base: URL? = nil,
        dataDirectory: URL? = nil,
        cancellation: CancellationFlag = CancellationFlag()
    ) -> GenerationRequest {
        GenerationRequest(
            geometry: CdTestSupport.geometry(),
            tone: tone,
            image: image ?? CdTestSupport.testImage(),
            outputFormat: format,
            dataDirectory: dataDirectory,
            outputBaseURL: base,
            cancellation: cancellation
        )
    }

    // MARK: - 协议契约

    func testEntryPointContract() {
        let generator = CdImageGenerator()
        XCTAssertEqual(generator.family, .cd)
        XCTAssertEqual(generator.sectorAlignment, 1)      // CD 每扇区 2352 字节，无需块对齐
        XCTAssertEqual(GenerationOutputFormat.options(for: .cd), [.wav, .raw, .iso])
    }

    func testRejectsNonCdGeometry() {
        var geometry = DiscPreset.dvd5_120mm.geometry()
        geometry.family = .dvd
        let request = GenerationRequest(
            geometry: geometry,
            image: CdTestSupport.testImage(),
            outputFormat: .raw
        )
        XCTAssertThrowsError(try CdImageGenerator().generate(request, to: DataSequentialSink()) { _ in }) { error in
            guard case DiscError.unsupported = error else {
                return XCTFail("应报 unsupported，实际 \(error)")
            }
        }
    }

    // MARK: - RAW

    func testRawOutputHasSectorLengthAndBigEndianOrder() throws {
        let sink = DataSequentialSink()
        let result = try CdImageGenerator().generate(request(format: .raw), to: sink) { _ in }

        XCTAssertEqual(sink.bytes.count, totalBytes)
        XCTAssertEqual(Int(result.byteCount), totalBytes)
        XCTAssertTrue(result.sidecarURLs.isEmpty)
        XCTAssertTrue(result.summary.contains("RAW"))
        // RAW 是大端：不交换相邻字节 → 文件内容就是延迟交织后的字节流。
        let sampler = CdImageSampler(image: CdTestSupport.testImage(), parameters: parameters)
        let tone = ToneProfile.legacyBinary
        for logical in [0, 1, 23, 24, 25, 5_000, totalBytes - 1] {
            let fileIndex = CddaInterleaveTable.fileIndex(forLogicalByte: logical)
            guard fileIndex < totalBytes else { continue }
            let expected = CdToneMapping.map(
                gray: sampler.gray(atByte: logical),
                tone: tone,
                sampleIndex: Int64(logical)
            )
            XCTAssertEqual(sink.bytes[fileIndex], expected, "逻辑字节 \(logical) 的值")
        }
    }

    // MARK: - WAV

    func testWaveOutputHasHeaderAndPcmLength() throws {
        let sink = DataSequentialSink()
        let result = try CdImageGenerator().generate(request(format: .wav), to: sink) { _ in }

        XCTAssertEqual(sink.bytes.count, totalBytes + 44)
        XCTAssertEqual(Int(result.byteCount), totalBytes + 44)
        XCTAssertEqual(CdTestSupport.ascii(sink.bytes, at: 0, count: 4), "RIFF")
        XCTAssertEqual(CdTestSupport.ascii(sink.bytes, at: 8, count: 4), "WAVE")
        XCTAssertEqual(CdTestSupport.littleEndian32(sink.bytes, at: 40), UInt32(totalBytes))
        XCTAssertEqual(CdTestSupport.littleEndian32(sink.bytes, at: 4), UInt32(totalBytes + 36))
        // 没有 outputBaseURL（内存模式）时不写 CUE。
        XCTAssertTrue(result.sidecarURLs.isEmpty)
    }

    func testWaveDataIsRawWithAdjacentBytesSwapped() throws {
        let rawSink = DataSequentialSink()
        _ = try CdImageGenerator().generate(request(format: .raw), to: rawSink) { _ in }

        let waveSink = DataSequentialSink()
        _ = try CdImageGenerator().generate(request(format: .wav), to: waveSink) { _ in }

        let audio = Array(waveSink.bytes.dropFirst(44))
        XCTAssertEqual(audio.count, rawSink.bytes.count)
        for index in 0..<audio.count {
            XCTAssertEqual(
                audio[index],
                rawSink.bytes[index ^ 1],
                "WAV data 应当等于 RAW 逐 16 位对换（索引 \(index)）"
            )
        }
    }

    func testCueIsWrittenBesideWaveFile() throws {
        let directory = try CdTestSupport.scratchDirectory()
        defer { CdTestSupport.remove(directory) }

        let wavURL = directory.appendingPathComponent("cd-track.wav")
        let sink = try FileSequentialSink(url: wavURL)
        let result = try CdImageGenerator().generate(
            request(format: .wav, base: directory.appendingPathComponent("cd-track")),
            to: sink
        ) { _ in }
        try sink.close()

        XCTAssertEqual(result.sidecarURLs.count, 1)
        let cueURL = directory.appendingPathComponent("cd-track.cue")
        XCTAssertEqual(result.sidecarURLs.first, cueURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wavURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cueURL.path))

        let size = try FileManager.default.attributesOfItem(atPath: wavURL.path)[.size] as? Int
        XCTAssertEqual(size, totalBytes + 44)

        let cueData = try Data(contentsOf: cueURL)
        XCTAssertEqual(Array(cueData.prefix(3)), [0xEF, 0xBB, 0xBF])
        let cueText = String(decoding: cueData.dropFirst(3), as: UTF8.self)
        XCTAssertTrue(cueText.hasPrefix("FILE \"cd-track.wav\" WAVE\r\n"), "CUE 内容：\(cueText)")
        XCTAssertTrue(cueText.contains("TRACK 01 AUDIO"))
    }

    func testRawDoesNotWriteCue() throws {
        let directory = try CdTestSupport.scratchDirectory()
        defer { CdTestSupport.remove(directory) }

        let rawURL = directory.appendingPathComponent("cd-track.raw")
        let sink = try FileSequentialSink(url: rawURL)
        let result = try CdImageGenerator().generate(
            request(format: .raw, base: directory.appendingPathComponent("cd-track")),
            to: sink
        ) { _ in }
        try sink.close()

        XCTAssertTrue(result.sidecarURLs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("cd-track.cue").path))
        let size = try FileManager.default.attributesOfItem(atPath: rawURL.path)[.size] as? Int
        XCTAssertEqual(size, totalBytes)
    }

    // MARK: - 读回可复现（逻辑字节序号）

    /// 核心不变量：文件索引 `i + offset(i % 24)` 处的字节，等于「按逻辑字节序号 i 采样 + 调色」
    /// 的结果。影调开了抖动，所以如果实现拿文件位置当样本索引，这里必然失败。
    func testLogicalByteIndexReproducesReadback() throws {
        let tone = ToneProfile(ditherStrength: 0.75, levels: 2, brightness: 0)
        let image = CdTestSupport.testImage()
        let sink = DataSequentialSink()
        _ = try CdImageGenerator().generate(
            request(format: .raw, tone: tone, image: image),
            to: sink
        ) { _ in }

        let sampler = CdImageSampler(image: image, parameters: parameters)
        var compared = 0
        var ditherDiscriminating = 0
        for logical in 0..<totalBytes {
            let fileIndex = CddaInterleaveTable.fileIndex(forLogicalByte: logical)
            guard fileIndex < totalBytes else { continue }
            let gray = sampler.gray(atByte: logical)
            let expected = CdToneMapping.map(gray: gray, tone: tone, sampleIndex: Int64(logical))
            XCTAssertEqual(sink.bytes[fileIndex], expected, "逻辑字节 \(logical)")

            // 若错用文件位置作样本索引，至少有一个字节会不同（保证这条测试有鉴别力）。
            let withFileIndex = CdToneMapping.map(gray: gray, tone: tone, sampleIndex: Int64(fileIndex))
            if withFileIndex != expected { ditherDiscriminating += 1 }
            compared += 1
        }
        XCTAssertEqual(compared, totalBytes - CddaInterleaveTable.droppedTailByteCount(totalBytes: totalBytes))
        XCTAssertGreaterThan(ditherDiscriminating, 0, "抖动应让错误索引露馅")
    }

    func testEveryGeneratedByteIsPaletteMember() throws {
        let sink = DataSequentialSink()
        _ = try CdImageGenerator().generate(request(format: .raw, image: CdTestSupport.binaryImage()), to: sink) { _ in }
        let palette = Set(CdToneMapping.twoLevelPalette)
        // 延迟线尾部（1318–1332 字节）不会写出任何逻辑字节，那里保持初值 0，
        // 所以只检查「被某个逻辑字节覆盖」的文件位置。
        var covered = [Bool](repeating: false, count: totalBytes)
        for logical in 0..<totalBytes {
            let fileIndex = CddaInterleaveTable.fileIndex(forLogicalByte: logical)
            guard fileIndex < totalBytes else { continue }
            covered[fileIndex] = true
            XCTAssertTrue(palette.contains(sink.bytes[fileIndex]), "非调色板字节 0x\(String(sink.bytes[fileIndex], radix: 16))")
        }
        let uncovered = covered.filter { !$0 }.count
        XCTAssertEqual(uncovered, CddaInterleaveTable.droppedTailByteCount(totalBytes: totalBytes))
        for index in 0..<totalBytes where !covered[index] {
            XCTAssertEqual(sink.bytes[index], 0, "未覆盖的文件位置 \(index) 应保持初值 0")
        }
    }

    func testGenerationIsDeterministic() throws {
        let first = DataSequentialSink()
        let second = DataSequentialSink()
        let tone = ToneProfile(ditherStrength: 0.75, levels: 4, brightness: 0)
        _ = try CdImageGenerator().generate(request(format: .raw, tone: tone), to: first) { _ in }
        _ = try CdImageGenerator().generate(request(format: .raw, tone: tone), to: second) { _ in }
        XCTAssertEqual(first.bytes, second.bytes)
    }

    func testProgressEndsAtOne() throws {
        final class Collector: @unchecked Sendable {
            var stages: [String] = []
            var fractions: [Double] = []
        }
        let collector = Collector()
        _ = try CdImageGenerator().generate(request(format: .raw), to: DataSequentialSink()) { progress in
            collector.stages.append(progress.stage)
            collector.fractions.append(progress.fraction ?? -1)
        }
        XCTAssertFalse(collector.stages.isEmpty)
        XCTAssertEqual(collector.stages.first, "geometry")
        XCTAssertEqual(collector.fractions.last, 1.0)
        XCTAssertTrue(collector.stages.contains("mapping"))
    }

    func testCancellationStopsGeneration() {
        let flag = CancellationFlag()
        flag.cancel()
        let sink = DataSequentialSink()
        XCTAssertThrowsError(
            try CdImageGenerator().generate(request(format: .raw, cancellation: flag), to: sink) { _ in }
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    // MARK: - 数据盘模式（ISO9660 Mode 1 cooked 映像）

    func testIsoWithoutDataDirectoryIsRejected() {
        let sink = DataSequentialSink()
        XCTAssertThrowsError(
            try CdImageGenerator().generate(request(format: .iso), to: sink) { _ in }
        ) { error in
            guard case DiscError.missingPayload = error else {
                return XCTFail("应报 missingPayload，实际 \(error)")
            }
        }
    }

    func testIsoWithMissingDirectoryIsRejected() {
        let directory = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        let sink = DataSequentialSink()
        XCTAssertThrowsError(
            try CdImageGenerator().generate(request(format: .iso, dataDirectory: directory), to: sink) { _ in }
        ) { error in
            guard case DiscError.missingPayload = error else {
                return XCTFail("应报 missingPayload，实际 \(error)")
            }
        }
    }

    /// 内圈布局：元数据 → 文件 → 绘图区（到卷尾）。文件长度 = 扇区数 × 2048。
    func testIsoDataModeInnerRingEndsWithDrawingRegion() throws {
        let directory = try CdTestSupport.scratchDirectory()
        defer { CdTestSupport.remove(directory) }
        try CdTestSupport.makeDataFolder(at: directory)

        let sectors = 200
        let geometry = CdTestSupport.geometry(sectors: sectors)
        let parameters = CdDiscParameters(geometry: geometry)
        let tone = ToneProfile(ditherStrength: 0.5, levels: 2, brightness: 0)
        let image = CdTestSupport.testImage()

        let sink = DataSequentialSink()
        let request = GenerationRequest(
            geometry: geometry,
            tone: tone,
            image: image,
            outputFormat: .iso,
            dataDirectory: directory,
            volumeLabel: "CD_IMAGE"
        )
        let result = try CdImageGenerator().generate(request, to: sink) { _ in }

        XCTAssertEqual(sink.bytes.count, sectors * 2048)
        XCTAssertEqual(Int(result.byteCount), sectors * 2048)
        XCTAssertTrue(result.summary.contains("绘图区"))

        // ISO9660 主卷描述符：LBA 16、类型 1、"CD001"、版本 1。
        let pvd = 16 * 2048
        XCTAssertEqual(sink.bytes[pvd], 1)
        XCTAssertEqual(CdTestSupport.ascii(sink.bytes, at: pvd + 1, count: 5), "CD001")
        XCTAssertEqual(sink.bytes[pvd + 6], 1)

        // 绘图区一直铺到卷尾：最后一个扇区应逐字节等于补偿后的 payload。
        let sampler = CdImageSampler(image: image, parameters: parameters)
        let lastSector = Array(sink.bytes[((sectors - 1) * 2048)..<(sectors * 2048)])
        XCTAssertEqual(lastSector, CdDataPayload.drawingPayload(lba: sectors - 1, sampler: sampler, tone: tone))
    }

    /// 外圈布局：元数据 → 绘图区 → 文件（到卷尾）。最后一个扇区不再是绘图。
    func testIsoDataModeOuterRingPutsFilesAtTheEnd() throws {
        let directory = try CdTestSupport.scratchDirectory()
        defer { CdTestSupport.remove(directory) }
        try CdTestSupport.makeDataFolder(at: directory)

        let sectors = 200
        let geometry = CdTestSupport.geometry(sectors: sectors)
        let parameters = CdDiscParameters(geometry: geometry)
        let tone = ToneProfile(ditherStrength: 0.5, levels: 2, brightness: 0)
        let image = CdTestSupport.testImage()

        let sink = DataSequentialSink()
        let request = GenerationRequest(
            geometry: geometry,
            tone: tone,
            image: image,
            outputFormat: .iso,
            dataDirectory: directory,
            dataAtOuterRing: true,
            volumeLabel: "CD_IMAGE"
        )
        _ = try CdImageGenerator().generate(request, to: sink) { _ in }
        XCTAssertEqual(sink.bytes.count, sectors * 2048)

        let sampler = CdImageSampler(image: image, parameters: parameters)
        let lastSector = Array(sink.bytes[((sectors - 1) * 2048)..<(sectors * 2048)])
        XCTAssertNotEqual(lastSector, CdDataPayload.drawingPayload(lba: sectors - 1, sampler: sampler, tone: tone))
        // 文件内容确实写在了盘尾（测试夹具里的文本会原样出现）。
        let tail = String(decoding: sink.bytes[((sectors - 4) * 2048)...], as: UTF8.self)
        XCTAssertTrue(tail.contains("disc image studio"), "盘尾应含文件内容，实际尾段：\(tail.prefix(80))")
    }

    func testIsoDataModeRejectsFolderWithoutDrawingRoom() throws {
        let directory = try CdTestSupport.scratchDirectory()
        defer { CdTestSupport.remove(directory) }
        try CdTestSupport.makeDataFolder(at: directory)

        // 数据文件夹本身就要 20 多个扇区，盘只给 20 个 → 没有绘图区。
        var geometry = CdTestSupport.geometry(sectors: 20)
        geometry.sectors = 20
        let request = GenerationRequest(
            geometry: geometry,
            tone: ToneProfile.legacyBinary,
            image: CdTestSupport.testImage(),
            outputFormat: .iso,
            dataDirectory: directory
        )
        XCTAssertThrowsError(try CdImageGenerator().generate(request, to: DataSequentialSink()) { _ in }) { error in
            if case DiscError.unsupported = error { return }        // 文件系统本身就放不下
            if case DiscError.invalidGeometry = error { return }    // 放得下但没有绘图区
            XCTFail("应报容量不足，实际 \(error)")
        }
    }
}
