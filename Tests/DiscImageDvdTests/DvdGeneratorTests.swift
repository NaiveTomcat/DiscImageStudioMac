import DiscImageCore
import XCTest

@testable import DiscImageDvd

/// `DvdImageGenerator` 端到端：纯绘图 / 数据盘 / 内外圈 / 取消与参数校验。
///
/// 测试一律用 96 扇区的小盘（6 个 ECC Block），不跑整张 DVD。
final class DvdGeneratorTests: XCTestCase {
    private let sectors = 96

    private func geometry(sectors: Int? = nil) -> DiscGeometry {
        DiscGeometry(
            family: .dvd,
            innerRadiusMm: 24,
            outerRadiusMm: 58,
            sectors: sectors ?? self.sectors,
            channelBitLengthNm: 133.3
        )
    }

    private func request(
        image: RasterImage,
        dataDirectory: URL? = nil,
        dataAtOuterRing: Bool = false,
        tone: ToneProfile = .default,
        outputFormat: GenerationOutputFormat = .iso,
        cancellation: CancellationFlag = CancellationFlag(),
        volumeLabel: String = "DVD_IMAGE"
    ) -> GenerationRequest {
        GenerationRequest(
            geometry: geometry(),
            tone: tone,
            image: image,
            outputFormat: outputFormat,
            dataDirectory: dataDirectory,
            dataAtOuterRing: dataAtOuterRing,
            volumeLabel: volumeLabel,
            clockwise: true,
            cancellation: cancellation
        )
    }

    private func generate(_ request: GenerationRequest) throws -> [UInt8] {
        let sink = DataSequentialSink(capacity: request.geometry.sectors * 2048)
        _ = try DvdImageGenerator().generate(request, to: sink) { _ in }
        return sink.bytes
    }

    private func drawingStartForPureDisc() throws -> Int {
        let plan = try Iso9660Writer.plan(entries: [], volumeSectors: sectors, volumeLabel: "DVD_IMAGE")
        return alignToBlock(plan.metadataEndLbaExclusive)
    }

    private func alignToBlock(_ lba: Int) -> Int {
        let block = DvdConstants.sectorsPerBlock
        let remainder = lba % block
        return remainder == 0 ? lba : lba + (block - remainder)
    }

    private func mask(lba: Int) -> [UInt8] {
        DvdDataFrameBuilder.payloadScramblerMask(
            physicalSectorNumber: UInt32(lba) + DvdConstants.physicalSectorNumberOffset
        )
    }

    // MARK: - 纯绘图

    func testWhiteImagePaintsWhiteScrambledBytes() throws {
        let bytes = try generate(request(image: RasterImage.gray(width: 8, height: 8, value: 255)))
        XCTAssertEqual(bytes.count, sectors * 2048)
        let drawingStart = try drawingStartForPureDisc()
        XCTAssertGreaterThan(drawingStart, 16)
        // 绘图区之前的系统区/元数据必须不是纹理（PVD 在 LBA 16）。
        XCTAssertEqual(bytes[16 * 2048], 1)
        XCTAssertEqual(Array(bytes[(16 * 2048 + 1)..<(16 * 2048 + 6)]), Array("CD001".utf8))

        for lba in drawingStart..<sectors {
            let scrambler = mask(lba: lba)
            let base = lba * 2048
            for index in 0..<2048 {
                XCTAssertEqual(
                    bytes[base + index],
                    DvdConstants.whiteScrambledByte ^ scrambler[index],
                    "LBA \(lba) 字节 \(index) 不是白色扰码值"
                )
            }
        }
    }

    func testBlackImagePaintsBlackScrambledBytes() throws {
        let bytes = try generate(request(image: RasterImage.gray(width: 8, height: 8, value: 0)))
        let drawingStart = try drawingStartForPureDisc()
        for lba in drawingStart..<sectors {
            let scrambler = mask(lba: lba)
            let base = lba * 2048
            for index in 0..<2048 {
                XCTAssertEqual(
                    bytes[base + index],
                    DvdConstants.blackScrambledByte ^ scrambler[index],
                    "LBA \(lba) 字节 \(index) 不是黑色扰码值"
                )
            }
        }
    }

    func testWhiteAndBlackDifferByConstantXor() throws {
        let white = try generate(request(image: RasterImage.gray(width: 8, height: 8, value: 255)))
        let black = try generate(request(image: RasterImage.gray(width: 8, height: 8, value: 0)))
        let drawingStart = try drawingStartForPureDisc()
        for lba in drawingStart..<sectors {
            for index in 0..<2048 {
                let offset = lba * 2048 + index
                XCTAssertEqual(white[offset] ^ black[offset], 0x37, "0xA5 ^ 0x92 必须等于 0x37")
            }
        }
    }

    func testMidGrayImageUsesBothTextures() throws {
        let bytes = try generate(request(image: RasterImage.gray(width: 8, height: 8, value: 128)))
        let drawingStart = try drawingStartForPureDisc()
        var sawWhite = false
        var sawBlack = false
        for lba in drawingStart..<sectors {
            let scrambler = mask(lba: lba)
            let base = lba * 2048
            for index in 0..<2048 {
                let q = bytes[base + index] ^ scrambler[index]
                if q == DvdConstants.whiteScrambledByte {
                    sawWhite = true
                } else if q == DvdConstants.blackScrambledByte {
                    sawBlack = true
                } else {
                    XCTFail("出现了第三种纹理 0x\(String(q, radix: 16))")
                }
            }
        }
        XCTAssertTrue(sawWhite, "中调应该出现白色纹理")
        XCTAssertTrue(sawBlack, "中调应该出现黑色纹理")
    }

    func testTinyGeometryFallsBackToRawPayload() throws {
        // 16 扇区放不下 ISO9660 元数据：退化为纯 payload 映像（第一条扇区就是纹理）。
        let tiny = DiscGeometry(
            family: .dvd,
            innerRadiusMm: 24,
            outerRadiusMm: 58,
            sectors: 16,
            channelBitLengthNm: 133.3
        )
        let request = GenerationRequest(
            geometry: tiny,
            tone: .default,
            image: RasterImage.gray(width: 8, height: 8, value: 255),
            outputFormat: .iso,
            clockwise: true
        )
        let sink = DataSequentialSink(capacity: 16 * 2048)
        let result = try DvdImageGenerator().generate(request, to: sink) { _ in }
        XCTAssertEqual(result.byteCount, Int64(16 * 2048))
        XCTAssertTrue(result.summary.contains("无文件系统"))
        let scrambler = mask(lba: 0)
        for index in 0..<2048 {
            XCTAssertEqual(sink.bytes[index], DvdConstants.whiteScrambledByte ^ scrambler[index])
        }
    }

    // MARK: - 数据盘

    func testDataDiscInnerRing() throws {
        let temp = try TemporaryDirectory()
        let hello = Array("Hello from the DVD data disc!".utf8)
        try temp.write("hello.txt", bytes: hello)
        try temp.write("docs/readme.md", text: "readme")
        try temp.write("docs/子目录/note.txt", text: "note")

        let bytes = try generate(request(image: RasterImage.gray(width: 8, height: 8, value: 255), dataDirectory: temp.url))
        XCTAssertEqual(bytes.count, sectors * 2048)
        let reader = IsoReader(bytes)
        XCTAssertEqual(reader.ascii(at: 16, offset: 1, length: 5), "CD001")

        let entries = try FileTree.scan(root: temp.url)
        let plan = try Iso9660Writer.plan(entries: entries, volumeSectors: sectors, volumeLabel: "DVD_IMAGE")
        XCTAssertEqual(plan.fileCount, 3)
        XCTAssertEqual(plan.directoryCount, 3)

        let rootRecord = reader.rootRecord(descriptorLba: 16)
        let rootLba = IsoReader.recordExtentLba(rootRecord)
        guard let helloRecord = reader.find(
            identifier: Array("HELLO.TXT;1".utf8),
            inDirectoryAt: rootLba,
            byteCount: IsoReader.recordDataLength(rootRecord)
        ) else {
            return XCTFail("根目录里找不到 HELLO.TXT;1")
        }
        let helloLba = IsoReader.recordExtentLba(helloRecord)
        XCTAssertEqual(IsoReader.recordDataLength(helloRecord), hello.count)
        XCTAssertEqual(reader.contents(atExtent: helloLba, length: hello.count), hello)
        // 文件必须在绘图区之前（内圈）。
        XCTAssertLessThan(helloLba, alignToBlock(plan.dataEndLbaExclusive))

        // 绘图区是白色纹理。
        let drawingStart = alignToBlock(plan.dataEndLbaExclusive)
        XCTAssertGreaterThanOrEqual(sectors - drawingStart, 16)
        for lba in drawingStart..<sectors {
            let scrambler = mask(lba: lba)
            let base = lba * 2048
            for index in 0..<2048 {
                XCTAssertEqual(bytes[base + index], DvdConstants.whiteScrambledByte ^ scrambler[index])
            }
        }
    }

    func testDataDiscOuterRing() throws {
        let temp = try TemporaryDirectory()
        let hello = Array("outer ring data".utf8)
        try temp.write("hello.txt", bytes: hello)
        let bytes = try generate(request(
            image: RasterImage.gray(width: 8, height: 8, value: 255),
            dataDirectory: temp.url,
            dataAtOuterRing: true
        ))
        let reader = IsoReader(bytes)
        let entries = try FileTree.scan(root: temp.url)
        let plan = try Iso9660Writer.plan(
            entries: entries,
            volumeSectors: sectors,
            volumeLabel: "DVD_IMAGE",
            filesAtOuterRing: true
        )
        let outerRootRecord = reader.rootRecord(descriptorLba: 16)
        let rootLba = IsoReader.recordExtentLba(outerRootRecord)
        guard let helloRecord = reader.find(
            identifier: Array("HELLO.TXT;1".utf8),
            inDirectoryAt: rootLba,
            byteCount: IsoReader.recordDataLength(outerRootRecord)
        ) else {
            return XCTFail("根目录里找不到 HELLO.TXT;1")
        }
        let helloLba = IsoReader.recordExtentLba(helloRecord)
        XCTAssertGreaterThanOrEqual(helloLba, plan.fileDataStartLba, "外圈文件必须贴卷尾")
        XCTAssertEqual(reader.contents(atExtent: helloLba, length: hello.count), hello)

        // 元数据与外圈文件之间是绘图区：白色纹理。
        let drawingStart = alignToBlock(plan.metadataEndLbaExclusive)
        let drawingEnd = (plan.fileDataStartLba / 16) * 16
        XCTAssertGreaterThanOrEqual(drawingEnd - drawingStart, 16)
        for lba in drawingStart..<drawingEnd {
            let scrambler = mask(lba: lba)
            let base = lba * 2048
            for index in 0..<2048 {
                XCTAssertEqual(bytes[base + index], DvdConstants.whiteScrambledByte ^ scrambler[index])
            }
        }
    }

    func testDataDiscRejectsWhenNoRoomForDrawing() throws {
        let temp = try TemporaryDirectory()
        for index in 0..<40 {
            try temp.write("file\(index).bin", bytes: [UInt8](repeating: UInt8(index), count: 2048))
        }
        let tinySectors = 32
        let request = GenerationRequest(
            geometry: DiscGeometry(
                family: .dvd,
                innerRadiusMm: 24,
                outerRadiusMm: 58,
                sectors: tinySectors,
                channelBitLengthNm: 133.3
            ),
            tone: .default,
            image: RasterImage.gray(width: 8, height: 8, value: 0),
            outputFormat: .iso,
            dataDirectory: temp.url,
            clockwise: true
        )
        let sink = DataSequentialSink()
        XCTAssertThrowsError(try DvdImageGenerator().generate(request, to: sink) { _ in }) { error in
            guard case DiscError.unsupported = error else {
                return XCTFail("期望 unsupported（放不下），实际 \(error)")
            }
        }
    }

    // MARK: - 取消 / 参数校验

    func testCancellationIsObserved() {
        let flag = CancellationFlag()
        flag.cancel()
        let request = request(image: RasterImage.gray(width: 8, height: 8, value: 0), cancellation: flag)
        XCTAssertThrowsError(try generate(request)) { error in
            XCTAssertTrue(error is CancellationError, "取消必须抛 CancellationError，实际 \(error)")
        }
    }

    func testRejectsUnsupportedFormatToneAndFamily() {
        let image = RasterImage.gray(width: 8, height: 8, value: 0)
        XCTAssertThrowsError(
            try generate(request(image: image, outputFormat: .wav))
        ) { error in
            guard case DiscError.unsupported = error else { return XCTFail("期望 unsupported，实际 \(error)") }
        }
        XCTAssertThrowsError(
            try generate(request(image: image, tone: ToneProfile(ditherStrength: 0.5, levels: 4)))
        ) { error in
            guard case DiscError.unsupported = error else { return XCTFail("期望 unsupported，实际 \(error)") }
        }
        var cdGeometry = geometry()
        cdGeometry.family = .cd
        let cdRequest = GenerationRequest(
            geometry: cdGeometry,
            tone: .default,
            image: image,
            outputFormat: .iso,
            clockwise: true
        )
        XCTAssertThrowsError(try generate(cdRequest)) { error in
            guard case DiscError.invalidGeometry = error else { return XCTFail("期望 invalidGeometry，实际 \(error)") }
        }
    }

    func testProgressReachesCompletion() throws {
        let sink = DataSequentialSink()
        var stages: [String] = []
        var lastFraction = 0.0
        let request = request(image: RasterImage.gray(width: 8, height: 8, value: 0))
        _ = try DvdImageGenerator().generate(request, to: sink) { progress in
            stages.append(progress.stage)
            if let fraction = progress.fraction {
                XCTAssertGreaterThanOrEqual(fraction, lastFraction)
                lastFraction = fraction
            }
        }
        XCTAssertTrue(stages.contains("mapping"))
        XCTAssertTrue(stages.contains("finalize"))
        XCTAssertEqual(lastFraction, 1, accuracy: 1e-9)
    }

    // MARK: - 可复现性 / 串行与并行一致

    func testSourceDateEpochPinsGenerationTimestamp() {
        let pinned = DvdImageGenerator.generationTimestamp(
            environment: ["SOURCE_DATE_EPOCH": "1793605888.14"]
        )
        XCTAssertEqual(pinned.timeIntervalSince1970, 1793605888.14, accuracy: 1e-6)

        // 未设置时退回「现在」，并且非法值不参与（走默认）。
        XCTAssertEqual(
            DvdImageGenerator.generationTimestamp(environment: [:]).timeIntervalSinceNow,
            0,
            accuracy: 30
        )
        XCTAssertEqual(
            DvdImageGenerator.generationTimestamp(environment: ["SOURCE_DATE_EPOCH": "not-a-number"])
                .timeIntervalSinceNow,
            0,
            accuracy: 30
        )
    }

    /// 串行（`DISCI_MAX_WORKERS=1`）与默认并行必须逐字节一致。
    /// 用 `SOURCE_DATE_EPOCH` 钉住 ISO 的日期字段，否则时间戳会让每次输出不同。
    func testSerialAndParallelOutputsAreIdentical() throws {
        let previousEpoch = ProcessInfo.processInfo.environment["SOURCE_DATE_EPOCH"]
        let previousWorkers = ProcessInfo.processInfo.environment["DISCI_MAX_WORKERS"]
        defer {
            if let value = previousEpoch { setenv("SOURCE_DATE_EPOCH", value, 1) } else { unsetenv("SOURCE_DATE_EPOCH") }
            if let value = previousWorkers { setenv("DISCI_MAX_WORKERS", value, 1) } else { unsetenv("DISCI_MAX_WORKERS") }
        }
        setenv("SOURCE_DATE_EPOCH", "1793605888.14", 1)

        let request = request(image: RasterImage.gray(width: 16, height: 16, value: 128))
        setenv("DISCI_MAX_WORKERS", "1", 1)
        let serial = try generate(request)
        setenv("DISCI_MAX_WORKERS", "8", 1)
        let parallel = try generate(request)
        XCTAssertEqual(serial, parallel, "并行与串行的输出必须逐字节一致")
        XCTAssertEqual(serial.count, sectors * 2048)
    }

    // MARK: - 供 hdiutil 实测的产物

    /// 生成一个可挂载的 ISO 到 `.build/verify/`（不自动删除，供
    /// `hdiutil attach` 手工验证；见交付说明）。
    func testWritesIsoArtifactForMountTest() throws {
        let temp = try TemporaryDirectory()
        try temp.write("hello.txt", bytes: Array("Hello, disc! 你好".utf8))
        try temp.write("docs/readme.md", text: "# DVD data disc\n")
        // 从测试文件路径回溯到包根目录，避免依赖测试进程的 CWD。
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = packageRoot.appendingPathComponent(".build/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("dvd-data.iso")
        try? FileManager.default.removeItem(at: output)

        let sink = try FileSequentialSink(url: output)
        let effect = try DvdImageGenerator().generate(
            GenerationRequest(
                geometry: geometry(),
                tone: .default,
                image: RasterImage.gray(width: 16, height: 16, value: 255),
                outputFormat: .iso,
                dataDirectory: temp.url,
                volumeLabel: "DVD_IMAGE",
                clockwise: true
            ),
            to: sink
        ) { _ in }
        try sink.close()

        XCTAssertEqual(effect.byteCount, Int64(sectors * 2048))
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.int64Value, Int64(sectors * 2048))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    /// 纯绘图模式的 ISO 也要能挂载（HANDOFF §7 的 CLI 验收路径）。
    /// 产物留在 `.build/verify/` 供 `hdiutil attach` 手工验证。
    func testWritesDrawingIsoArtifactForMountTest() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = packageRoot.appendingPathComponent(".build/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("dvd-drawing.iso")
        try? FileManager.default.removeItem(at: output)

        let sink = try FileSequentialSink(url: output)
        let effect = try DvdImageGenerator().generate(
            request(image: RasterImage.gray(width: 16, height: 16, value: 255)),
            to: sink
        ) { _ in }
        try sink.close()

        XCTAssertEqual(effect.byteCount, Int64(sectors * 2048))
        let reader = IsoReader(try Data(contentsOf: output).map { $0 })
        XCTAssertEqual(reader.ascii(at: 16, offset: 1, length: 5), "CD001")
        XCTAssertEqual(reader.ascii(at: 17, offset: 1, length: 5), "CD001")
        XCTAssertEqual(reader.byte(at: 18, offset: 0), 255)
        let rootRecord = reader.rootRecord(descriptorLba: 16)
        XCTAssertEqual(IsoReader.recordExtentLba(rootRecord), IsoReader.recordExtentLba(rootRecord))
        // 根目录为空：只有 . 与 ..
        let records = reader.records(
            inDirectoryAt: IsoReader.recordExtentLba(rootRecord),
            byteCount: IsoReader.recordDataLength(rootRecord)
        )
        XCTAssertEqual(records.count, 2)
    }
}
