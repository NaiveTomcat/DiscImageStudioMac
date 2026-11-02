import XCTest
import DiscImageCore
@testable import DiscImageBluRay

/// UDF 2.01 写入器、生成入口与 sidecar 的端到端测试。
///
/// 规模控制：全部使用 640–1024 扇区的小镜像（1.25–2 MiB），不生成整张 25 GB；
/// 3 GiB 稀疏文件只用于验证「>4 GiB 文件按 0x3ffff800 拆 extent」的规划，
/// 不实际写出 3 GiB 镜像。
final class GeneratorAndUDFTests: XCTestCase {
    // MARK: - UDF 规划

    func testUDFPlanInnerLayout() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("hello bluray\n", to: directory.appendingPathComponent("readme.txt"))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try write("second file\n", to: directory.appendingPathComponent("sub/note.txt"))

        let plan = try UDFImageWriter.plan(
            sourceDirectory: directory, volumeSectors: 640, volumeLabel: "BD_TEST"
        )
        XCTAssertEqual(plan.volumeSectors, 640)
        XCTAssertEqual(plan.partitionStartLBA, 288)
        XCTAssertEqual(plan.fileCount, 2)
        XCTAssertEqual(plan.directoryCount, 2)          // 根目录 + sub
        XCTAssertEqual(plan.drawingStartLBA, 320)
        XCTAssertEqual(plan.drawingEndLBAExclusive, (640 - 257) / 32 * 32)
        XCTAssertEqual(plan.drawingStartLBA % 32, 0)
        XCTAssertEqual(plan.drawingEndLBAExclusive % 32, 0)
        XCTAssertLessThan(plan.drawingStartLBA, plan.drawingEndLBAExclusive)
        XCTAssertLessThanOrEqual(plan.dataEndLBAExclusive, plan.drawingStartLBA)
        XCTAssertEqual(plan.reserveVDSLBA, 384)
        XCTAssertEqual(plan.volumeLabel, "BD_TEST")
    }

    func testUDFPlanOuterLayout() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("x", to: directory.appendingPathComponent("a.txt"))

        let plan = try UDFImageWriter.plan(
            sourceDirectory: directory, volumeSectors: 1024, volumeLabel: "OUTER",
            filesAtOuterRing: true
        )
        // 外圈模式：绘图区留在前面（从 288 开始），文件分区贴到盘尾保留区之前。
        XCTAssertEqual(plan.drawingStartLBA, 288)
        XCTAssertGreaterThan(plan.partitionStartLBA, 288)
        XCTAssertEqual(plan.drawingEndLBAExclusive, plan.partitionStartLBA)
        XCTAssertEqual(plan.partitionStartLBA % 32, 0)
        XCTAssertGreaterThan(plan.drawingStartLBA, 0)
        XCTAssertLessThan(plan.drawingStartLBA, plan.drawingEndLBAExclusive)
        XCTAssertLessThanOrEqual(plan.partitionSectors, plan.dataEndLBAExclusive - 288 + 31)
    }

    func testUDFPlanRejectsInvalidVolumeSize() {
        XCTAssertThrowsError(try UDFImageWriter.plan(
            sourceDirectory: nil, volumeSectors: 512, volumeLabel: "T"))
        XCTAssertThrowsError(try UDFImageWriter.plan(
            sourceDirectory: nil, volumeSectors: 641, volumeLabel: "T"))
    }

    func testUDFPlanEmptyVolumeStillHasRoot() throws {
        let plan = try UDFImageWriter.plan(sourceDirectory: nil, volumeSectors: 640, volumeLabel: "EMPTY")
        XCTAssertEqual(plan.fileCount, 0)
        XCTAssertEqual(plan.partitionStartLBA, 288)
        XCTAssertLessThan(plan.drawingStartLBA, plan.drawingEndLBAExclusive)
    }

    func testUDFRejectsSymbolicLinks() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("real.txt")
        try write("x", to: target)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link.txt"), withDestinationURL: target)
        XCTAssertThrowsError(try UDFImageWriter.plan(
            sourceDirectory: directory, volumeSectors: 640, volumeLabel: "T")) { error in
            guard case DiscError.io = error else {
                return XCTFail("应当以 DiscError.io 拒绝符号链接，实际：\(error)")
            }
        }
    }

    func testFileIdentifierStraddleRule() {
        // UDF 2.01 §2.3.4.4：后续 FID 的 16 字节标签不能跨扇区，必要时补 32 字节。
        let base = BluRaySpec.bytesPerSector
        XCTAssertEqual(UDFImageWriter.fileIdentifierLength(identifierBytes: 8, directoryOffset: 0), 48)
        // 目录偏移让 FID 的尾部落在最后 16 字节内 → 补 32 字节实现使用区。
        let offset = base - 56
        XCTAssertEqual(UDFImageWriter.fileIdentifierLength(identifierBytes: 8, directoryOffset: offset), 80)
    }

    func testIdentifierEncoding() throws {
        let ascii = try UDFImageWriter.encodeIdentifier("readme.txt")
        XCTAssertEqual(ascii[0], 8)                 // 8 位 CS0
        XCTAssertEqual(ascii.count, 1 + 10)
        XCTAssertEqual(String(decoding: ascii[1...], as: UTF8.self), "readme.txt")

        let unicode = try UDFImageWriter.encodeIdentifier("蓝光盘")
        XCTAssertEqual(unicode[0], 16)              // 16 位 CS0（大端 UTF-16）
        XCTAssertEqual(unicode.count, 1 + 3 * 2)
    }

    func testDescriptorTagsHaveValidCRC() throws {
        let plan = try UDFImageWriter.plan(sourceDirectory: nil, volumeSectors: 640, volumeLabel: "TAG")
        let primary = UDFImageWriter.primaryDescriptor(plan: plan, location: 32)
        // 描述符标签：id=1、版本=3、CRC 覆盖 16..<512、checksum 覆盖 0..16（byte 4 除外）。
        XCTAssertEqual(UInt16(primary[0]) | UInt16(primary[1]) << 8, 1)
        XCTAssertEqual(UInt16(primary[2]) | UInt16(primary[3]) << 8, 3)
        XCTAssertEqual(UInt16(primary[10]) | UInt16(primary[11]) << 8, 512 - 16)
        XCTAssertEqual(readUInt32(primary, 12), 32)
        var checksum = 0
        for index in 0..<16 where index != 4 { checksum += Int(primary[index]) }
        XCTAssertEqual(primary[4], UInt8(checksum & 0xFF))

        var crc: UInt16 = 0
        for index in 16..<512 {
            crc ^= UInt16(primary[index]) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : (crc << 1)
            }
        }
        XCTAssertEqual(UInt16(primary[8]) | UInt16(primary[9]) << 8, crc)
    }

    func testLargeFileSplitsIntoExtents() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bigURL = directory.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: bigURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: bigURL)
        try handle.truncate(atOffset: 3 * 1_073_741_824)   // 3 GiB 稀疏文件
        try handle.close()

        let volumeSectors: UInt32 = 2_097_152                 // 4 GiB 卷，容纳 3 GiB 文件
        let plan = try UDFImageWriter.plan(
            sourceDirectory: directory, volumeSectors: volumeSectors, volumeLabel: "BIG")
        guard let node = plan.nodes.first(where: { $0.name == "big.bin" }) else {
            return XCTFail("规划里找不到 big.bin")
        }
        XCTAssertEqual(node.dataLength, 3 * 1_073_741_824)
        let entry = UDFImageWriter.fileEntry(plan: plan, node: node)
        let descriptorBytes = Int(readUInt32(entry, 172))
        let extentCount = descriptorBytes / 8
        let expected = Int((node.dataLength + UDFImageWriter.maximumExtentBytes - 1) / UDFImageWriter.maximumExtentBytes)
        XCTAssertEqual(extentCount, expected)
        XCTAssertGreaterThan(extentCount, 1, "3 GiB 文件必须拆成多个 extent")
        var offset = 176
        var total: Int64 = 0
        var previousLBN: UInt32 = 0
        for index in 0..<extentCount {
            let length = Int64(readUInt32(entry, offset))
            let lbn = readUInt32(entry, offset + 4)
            XCTAssertLessThanOrEqual(length, UDFImageWriter.maximumExtentBytes)
            total += length
            if index > 0 { XCTAssertGreaterThan(lbn, previousLBN) }
            previousLBN = lbn
            offset += 8
        }
        XCTAssertEqual(total, node.dataLength)
    }

    // MARK: - 生成入口

    func testGeneratorProducesMountableUDFImage() throws {
        let workspace = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let directory = workspace.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write("hello bluray\n", to: directory.appendingPathComponent("readme.txt"))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try write(String(repeating: "A", count: 4096), to: directory.appendingPathComponent("sub/note.txt"))

        let outputBase = workspace.appendingPathComponent("out/bd-test")
        try FileManager.default.createDirectory(
            at: outputBase.deletingLastPathComponent(), withIntermediateDirectories: true)
        let isoURL = outputBase.appendingPathExtension("iso")

        let request = GenerationRequest(
            geometry: makeGeometry(sectors: 640),
            tone: .default,
            image: makeCheckerImage(size: 96),
            outputFormat: .iso,
            dataDirectory: directory,
            dataAtOuterRing: false,
            volumeLabel: "BD_TEST",
            outputBaseURL: outputBase
        )
        let sink = try FileSequentialSink(url: isoURL)
        let result = try BluRayImageGenerator().generate(request, to: sink) { _ in }
        try sink.close()

        XCTAssertEqual(result.byteCount, 640 * 2048)
        XCTAssertEqual(FileManager.default.fileSize(of: isoURL), 640 * 2048)
        XCTAssertEqual(result.sidecarURLs.count, 1)
        XCTAssertEqual(result.sidecarURLs[0].lastPathComponent, "bd-test-bd-r-image-v1.json")

        // 卷识别序列（BEA01 / NSR03 / TEA01）必须在 16…18 扇区。
        let data = try Data(contentsOf: isoURL)
        XCTAssertEqual(String(decoding: data[16 * 2048 + 1..<16 * 2048 + 6], as: UTF8.self), "BEA01")
        XCTAssertEqual(String(decoding: data[17 * 2048 + 1..<17 * 2048 + 6], as: UTF8.self), "NSR03")
        XCTAssertEqual(String(decoding: data[18 * 2048 + 1..<18 * 2048 + 6], as: UTF8.self), "TEA01")
        // 主卷描述符与锚点。
        let primary = Array(data[32 * 2048..<33 * 2048])
        XCTAssertEqual(UInt16(primary[0]) | UInt16(primary[1]) << 8, 1)
        let anchor = Array(data[256 * 2048..<257 * 2048])
        XCTAssertEqual(UInt16(anchor[0]) | UInt16(anchor[1]) << 8, 2)
        // 尾部锚点与备份卷描述符。
        let lastAnchor = Array(data[639 * 2048..<640 * 2048])
        XCTAssertEqual(UInt16(lastAnchor[0]) | UInt16(lastAnchor[1]) << 8, 2)

        // 旁写元数据可回读。
        let metadata = try BluRayISOMetadata.load(from: result.sidecarURLs[0])
        XCTAssertEqual(metadata.format, "bd-r-image-v1")
        XCTAssertEqual(metadata.totalSectors, 640)
        XCTAssertEqual(metadata.volumeLabel, "BD_TEST")
        XCTAssertFalse(metadata.invertMapping)
        XCTAssertEqual(metadata.tone.levels, 2)
        XCTAssertEqual(metadata.drawingStartSector % 32, 0)
        XCTAssertEqual(metadata.drawingEndSectorExclusive % 32, 0)
        XCTAssertGreaterThan(metadata.isoBytes, 0)
    }

    func testGeneratorPureDrawingHasNoFilesystem() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = GenerationRequest(
            geometry: makeGeometry(sectors: 64),
            tone: .default,
            image: makeCheckerImage(size: 32),
            outputFormat: .iso,
            dataDirectory: nil,
            volumeLabel: "DRAW",
            outputBaseURL: nil
        )
        let sink = try DataSequentialSink(capacity: 64 * 2048)
        let result = try BluRayImageGenerator().generate(request, to: sink) { _ in }
        XCTAssertEqual(result.byteCount, 64 * 2048)
        XCTAssertEqual(sink.bytes.count, 64 * 2048)
        XCTAssertTrue(result.sidecarURLs.isEmpty)
        // 纯绘图没有 UDF：第 16 扇区不是 BEA01。
        let sector16 = String(decoding: sink.bytes[16 * 2048 + 1..<16 * 2048 + 6], as: UTF8.self)
        XCTAssertNotEqual(sector16, "BEA01")
    }

    func testGeneratorWritesInvertedPolarityIntoMetadata() throws {
        let workspace = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let directory = workspace.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write("x", to: directory.appendingPathComponent("a.txt"))
        let outputBase = workspace.appendingPathComponent("inverted")
        var geometry = makeGeometry(sectors: 640)
        geometry.invertMapping = true
        let request = GenerationRequest(
            geometry: geometry,
            tone: .default,
            image: makeCheckerImage(size: 32),
            outputFormat: .iso,
            dataDirectory: directory,
            volumeLabel: "INV",
            outputBaseURL: outputBase
        )
        let sink = try DataSequentialSink(capacity: 640 * 2048)
        let result = try BluRayImageGenerator().generate(request, to: sink) { _ in }
        let metadata = try BluRayISOMetadata.load(from: result.sidecarURLs[0])
        XCTAssertTrue(metadata.invertMapping)
    }

    func testGeneratorRejectsInvalidRequests() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = makeCheckerImage(size: 16)

        // 非蓝光几何
        var wrongFamily = makeGeometry(sectors: 640)
        wrongFamily.family = .dvd
        XCTAssertThrowsError(try BluRayImageGenerator().generate(
            GenerationRequest(geometry: wrongFamily, image: image),
            to: DataSequentialSink(), progress: { _ in }))

        // 输出格式必须是 ISO
        XCTAssertThrowsError(try BluRayImageGenerator().generate(
            GenerationRequest(geometry: makeGeometry(sectors: 640), image: image, outputFormat: .wav),
            to: DataSequentialSink(), progress: { _ in }))

        // 影调必须是两阶
        var fourLevels = ToneProfile.default
        fourLevels.levels = 4
        XCTAssertThrowsError(try BluRayImageGenerator().generate(
            GenerationRequest(geometry: makeGeometry(sectors: 640), tone: fourLevels, image: image),
            to: DataSequentialSink(), progress: { _ in }))

        // 带数据目录时扇区数不足 UDF 下限（640）
        XCTAssertThrowsError(try BluRayImageGenerator().generate(
            GenerationRequest(geometry: makeGeometry(sectors: 32), image: image,
                              dataDirectory: directory),
            to: DataSequentialSink(), progress: { _ in }))
    }

    // MARK: - 图像映射

    func testRunLengthMappingThresholdAndInvert() {
        let normal = BluRayRunLengthMapping(invert: false)
        XCTAssertEqual(normal.map(gray: 0), 0xAA)
        XCTAssertEqual(normal.map(gray: 127), 0xAA)
        XCTAssertEqual(normal.map(gray: 128), 0x44)
        XCTAssertEqual(normal.map(gray: 255), 0x44)

        let inverted = BluRayRunLengthMapping(invert: true)
        XCTAssertEqual(inverted.map(gray: 0), 0x44)
        XCTAssertEqual(inverted.map(gray: 255), 0xAA)
    }

    func testImageMappingFillsEveryPayloadByte() throws {
        let geometry = try BluRayTrackGeometry(innerRadiusMm: 24, outerRadiusMm: 58, totalSectors: 640)
        // 全黑图 → 所有 payload 都是暗部字节。
        let mapping = BluRayImagePayloadMapping(
            image: .black(width: 32, height: 32),
            tone: .legacyBinary,
            geometry: geometry,
            invert: false
        )
        var payload = [UInt8](repeating: 0xFF, count: BluRaySpec.payloadBytesPerCluster)
        try mapping.fillPayload(firstSector: 0, into: &payload)
        XCTAssertTrue(payload.allSatisfy { $0 == 0xAA })
        XCTAssertEqual(Set(payload).count, 1)

        // 全白图 → 亮部字节。
        let whiteMapping = BluRayImagePayloadMapping(
            image: .gray(width: 32, height: 32, value: 255),
            tone: .legacyBinary,
            geometry: geometry,
            invert: false
        )
        payload = [UInt8](repeating: 0, count: BluRaySpec.payloadBytesPerCluster)
        try whiteMapping.fillPayload(firstSector: 0, into: &payload)
        XCTAssertTrue(payload.allSatisfy { $0 == 0x44 })

        // 反转极性。
        let invertedMapping = BluRayImagePayloadMapping(
            image: .black(width: 32, height: 32),
            tone: .legacyBinary,
            geometry: geometry,
            invert: true
        )
        payload = [UInt8](repeating: 0, count: BluRaySpec.payloadBytesPerCluster)
        try invertedMapping.fillPayload(firstSector: 0, into: &payload)
        XCTAssertTrue(payload.allSatisfy { $0 == 0x44 })
    }

    func testScrambledClusterRestoresScrambledDomainBytes() throws {
        let geometry = try BluRayTrackGeometry(innerRadiusMm: 24, outerRadiusMm: 58, totalSectors: 640)
        let mapping = BluRayImagePayloadMapping(
            image: .black(width: 32, height: 32),
            tone: .legacyBinary,
            geometry: geometry,
            invert: false
        )
        let cluster = try mapping.scrambledCluster(firstSector: 0)
        XCTAssertEqual(cluster.count, 65_536)
        // ISO 里的 host 字节应按簇首 PSN 的掩码加扰；再解扰必须回到 0xAA。
        let mask = BluRayScrambler.mask(physicalSectorNumber: BluRaySpec.firstLayer0PhysicalSector, length: 2048)
        for sector in 0..<32 {
            for index in stride(from: 0, to: 2048, by: 97) {
                XCTAssertEqual(cluster[sector * 2048 + index] ^ mask[index], 0xAA)
            }
        }
    }

    // MARK: - 贪心 DC 增量编码与参考实现一致

    func testIncrementalGreedyMatchesFullReencodeReference() throws {
        let psn = BluRaySpec.firstLayer0PhysicalSector
        let mask = BluRayScrambler.mask(physicalSectorNumber: psn)
        var userData = [UInt8](repeating: 0, count: 65_536)
        for sector in 0..<32 {
            for index in 0..<2048 { userData[sector * 2048 + index] = 0xAA ^ mask[index] }
        }
        let ecc = Array(try BluRayECCEncoder.encode(userData: userData, firstPhysicalSectorNumber: psn))
        let rub = try BluRayRecordingUnit.encode(userData: userData, firstPhysicalSectorNumber: psn)
        var level = rub.channelLevels[BluRaySpec.runInChannelBits - 1]
        var digitalSum = 0
        for index in 0..<BluRaySpec.runInChannelBits {
            digitalSum += rub.channelLevels[index] == 0 ? -1 : 1
        }
        var termination = false

        // 前 3 帧与「整帧重编码」参考贪心逐位对比（含 Figure 41 替换的向前看边界）。
        for frame in 0..<3 {
            let current = Array(ecc[(frame * 155)..<((frame + 1) * 155)])
            let next = Array(ecc[((frame + 1) * 155)..<((frame + 2) * 155)])
            let fast = try BluRayGreedyDCControl.encode(
                eccFrame: current, frameWithinAddressUnit: frame % 31,
                nextEccFrame: next, precedingFrameUsedTermination: termination,
                initialChannelLevel: level, initialDigitalSum: digitalSum
            )
            let reference = try greedyReference(
                eccFrame: current, frameWithinAddressUnit: frame % 31,
                nextEccFrame: next, precedingTermination: termination,
                initialLevel: level, initialDigitalSum: digitalSum
            )
            XCTAssertEqual(fast.dcControlBits, reference.controls, "第 \(frame) 帧 DC 控制位与参考实现不一致")
            XCTAssertEqual(fast.frame.modulationBits, reference.frame.modulationBits, "第 \(frame) 帧调制位与参考实现不一致")
            level = fast.frame.finalChannelLevel
            termination = fast.frame.usedTermination
            digitalSum += fast.frame.digitalSum
        }
    }

    // MARK: - 可选的真实挂载测试

    /// 默认跳过：用 `BLURAY_MOUNT_TEST=1 swift test --filter ...` 打开。
    /// 需要一个允许 `hdiutil attach/detach` 的环境（DSH 沙箱内手工验证已通过）。
    func testGeneratedISOCanBeMounted() throws {
        guard ProcessInfo.processInfo.environment["BLURAY_MOUNT_TEST"] == "1" else {
            throw XCTSkip("设置 BLURAY_MOUNT_TEST=1 才执行 hdiutil 挂载测试")
        }
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("mount me\n", to: directory.appendingPathComponent("readme.txt"))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try write("nested\n", to: directory.appendingPathComponent("sub/note.txt"))

        let workspace = directory.deletingLastPathComponent()
            .appendingPathComponent("out-mount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let outputBase = workspace.appendingPathComponent("mount-test")
        try FileManager.default.createDirectory(
            at: outputBase.deletingLastPathComponent(), withIntermediateDirectories: true)
        let isoURL = outputBase.appendingPathExtension("iso")
        let request = GenerationRequest(
            geometry: makeGeometry(sectors: 640),
            tone: .default,
            image: makeCheckerImage(size: 64),
            outputFormat: .iso,
            dataDirectory: directory,
            volumeLabel: "BD_MOUNT",
            outputBaseURL: outputBase
        )
        let sink = try FileSequentialSink(url: isoURL)
        _ = try BluRayImageGenerator().generate(request, to: sink) { _ in }
        try sink.close()

        let attach = try runProcess("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", isoURL.path])
        XCTAssertEqual(attach.status, 0, attach.output)
        let mountPoint = "/Volumes/BD_MOUNT"
        defer { _ = try? runProcess("/usr/bin/hdiutil", ["detach", mountPoint]) }
        let listing = try FileManager.default.contentsOfDirectory(atPath: mountPoint)
        XCTAssertTrue(listing.contains("readme.txt"))
        XCTAssertTrue(listing.contains("sub"))
        let contents = try String(contentsOfFile: mountPoint + "/sub/note.txt", encoding: .utf8)
        XCTAssertEqual(contents, "nested\n")
    }

    // MARK: - 辅助

    private func makeGeometry(sectors: Int) -> DiscGeometry {
        DiscGeometry(family: .bluRay, innerRadiusMm: 24, outerRadiusMm: 58, sectors: sectors)
    }

    private func makeCheckerImage(size: Int) -> RasterImage {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let value: UInt8 = ((x / 8 + y / 8) % 2 == 0) ? 0 : 255
                let offset = (y * size + x) * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 255
            }
        }
        return RasterImage(width: size, height: size, pixels: pixels)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bluray-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private func greedyReference(
        eccFrame: [UInt8],
        frameWithinAddressUnit: Int,
        nextEccFrame: [UInt8],
        precedingTermination: Bool,
        initialLevel: UInt8,
        initialDigitalSum: Int
    ) throws -> (controls: [UInt8], frame: BluRayRecordingFrame.Frame) {
        var controls = [UInt8](repeating: 0, count: BluRaySpec.dcControlBitsPerFrame)
        var selected: BluRayRecordingFrame.Frame?
        for control in 0..<controls.count {
            controls[control] = 0
            let zero = try BluRayRecordingFrame.encode(
                eccFrame: eccFrame, frameWithinAddressUnit: frameWithinAddressUnit,
                dcControlBits: controls, precedingFrameUsedTermination: precedingTermination,
                initialChannelLevel: initialLevel)
            controls[control] = 1
            let one = try BluRayRecordingFrame.encode(
                eccFrame: eccFrame, frameWithinAddressUnit: frameWithinAddressUnit,
                dcControlBits: controls, precedingFrameUsedTermination: precedingTermination,
                initialChannelLevel: initialLevel)
            let scoreZero = try BluRayGreedyDCControl.slowScore(
                frame: zero, control: control, nextEccFrame: nextEccFrame, nextDCControlBits: [],
                frameWithinAddressUnit: frameWithinAddressUnit, initialDigitalSum: initialDigitalSum)
            let scoreOne = try BluRayGreedyDCControl.slowScore(
                frame: one, control: control, nextEccFrame: nextEccFrame, nextDCControlBits: [],
                frameWithinAddressUnit: frameWithinAddressUnit, initialDigitalSum: initialDigitalSum)
            let chooseOne = scoreOne < scoreZero
            controls[control] = chooseOne ? 1 : 0
            selected = chooseOne ? one : zero
        }
        return (controls, selected!)
    }

    private func runProcess(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

private extension FileManager {
    func fileSize(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }
}
