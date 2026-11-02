import DiscImageCore
import XCTest

@testable import DiscImageDvd

/// ISO9660 / Joliet 写入器：布局、卷描述符、路径表、目录记录、内外圈放置与拒绝规则。
final class Iso9660WriterTests: XCTestCase {
    private let volumeSectors = 96

    // MARK: - 布局

    func testInnerRingLayout() throws {
        let temp = try TemporaryDirectory()
        try temp.write("hello.txt", text: "Hello, disc!")
        try temp.write("docs/readme.md", text: String(repeating: "abc", count: 200))
        let entries = try FileTree.scan(root: temp.url)
        let plan = try Iso9660Writer.plan(
            entries: entries,
            volumeSectors: volumeSectors,
            volumeLabel: "MY_DISC",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(plan.fileCount, 2)
        XCTAssertEqual(plan.directoryCount, 2)
        XCTAssertEqual(plan.metadataEndLbaExclusive, plan.fileDataStartLba)
        XCTAssertGreaterThan(plan.metadataEndLbaExclusive, 19)
        XCTAssertGreaterThan(plan.dataEndLbaExclusive, plan.fileDataStartLba)
        XCTAssertEqual(plan.fileBytes, Int64("Hello, disc!".utf8.count + 600))
        XCTAssertFalse(plan.filesAtOuterRing)
    }

    func testOuterRingLayout() throws {
        let temp = try TemporaryDirectory()
        try temp.write("hello.txt", text: "Hello, disc!")
        let entries = try FileTree.scan(root: temp.url)
        let plan = try Iso9660Writer.plan(
            entries: entries,
            volumeSectors: volumeSectors,
            volumeLabel: "OUTER",
            filesAtOuterRing: true
        )
        XCTAssertGreaterThan(plan.fileDataStartLba, plan.metadataEndLbaExclusive)
        XCTAssertEqual(plan.dataEndLbaExclusive, volumeSectors)
        XCTAssertEqual(plan.fileDataStartLba + 1, volumeSectors)
    }

    func testPlanRejectsTinyVolumeAndOversizedFile() throws {
        XCTAssertThrowsError(try Iso9660Writer.plan(entries: [], volumeSectors: 16, volumeLabel: "X")) { error in
            guard case DiscError.invalidGeometry = error else {
                return XCTFail("期望 invalidGeometry，实际 \(error)")
            }
        }
        let temp = try TemporaryDirectory()
        let url = try temp.write("big.bin", bytes: [0x00])
        let entries = [FileTreeEntry(relativePath: "big.bin", sourceURL: url, isDirectory: false, byteCount: 0x1_0000_0000)]
        XCTAssertThrowsError(try Iso9660Writer.plan(entries: entries, volumeSectors: volumeSectors, volumeLabel: "X")) { error in
            guard case DiscError.unsupported = error else {
                return XCTFail("期望 unsupported，实际 \(error)")
            }
        }
    }

    func testPlanRejectsSymlinkAndDuplicatePaths() throws {
        let temp = try TemporaryDirectory()
        let target = try temp.write("target.txt", text: "x")
        let link = temp.url.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let linkEntry = FileTreeEntry(relativePath: "link.txt", sourceURL: link, isDirectory: false, byteCount: 1)
        XCTAssertThrowsError(try Iso9660Writer.plan(entries: [linkEntry], volumeSectors: 64, volumeLabel: "X"))

        let fileEntry = FileTreeEntry(relativePath: "a.txt", sourceURL: target, isDirectory: false, byteCount: 1)
        XCTAssertThrowsError(
            try Iso9660Writer.plan(entries: [fileEntry, fileEntry], volumeSectors: 64, volumeLabel: "X")
        ) { error in
            guard case DiscError.io = error else {
                return XCTFail("期望 io，实际 \(error)")
            }
        }

        let traversal = FileTreeEntry(relativePath: "../escape.txt", sourceURL: target, isDirectory: false, byteCount: 1)
        XCTAssertThrowsError(try Iso9660Writer.plan(entries: [traversal], volumeSectors: 64, volumeLabel: "X"))
    }

    // MARK: - 卷描述符与路径表

    func testWriteAllProducesValidVolumeDescriptors() throws {
        let temp = try TemporaryDirectory()
        try temp.write("hello.txt", text: "Hello, disc!")
        let entries = try FileTree.scan(root: temp.url)
        let plan = try Iso9660Writer.plan(
            entries: entries,
            volumeSectors: volumeSectors,
            volumeLabel: "MY_DISC",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let sink = DataSequentialSink(capacity: volumeSectors * 2048)
        try Iso9660Writer.writeAll(plan, to: sink)
        XCTAssertEqual(sink.bytes.count, volumeSectors * 2048)

        let reader = IsoReader(sink.bytes)
        // PVD
        XCTAssertEqual(reader.byte(at: 16, offset: 0), 1)
        XCTAssertEqual(reader.ascii(at: 16, offset: 1, length: 5), "CD001")
        XCTAssertEqual(reader.byte(at: 16, offset: 6), 1)
        XCTAssertEqual(reader.u32le(at: 16, offset: 80), UInt32(volumeSectors))
        XCTAssertEqual(reader.u32be(at: 16, offset: 84), UInt32(volumeSectors))
        XCTAssertEqual(reader.u16le(at: 16, offset: 120), 1)
        XCTAssertEqual(reader.u16le(at: 16, offset: 124), 1)
        XCTAssertEqual(reader.u16le(at: 16, offset: 128), 2048)
        XCTAssertEqual(reader.u16be(at: 16, offset: 130), 2048)
        XCTAssertEqual(reader.ascii(at: 16, offset: 40, length: 7), "MY_DISC")
        // 路径表大小（both endian）
        let pathTableBytes = Int(reader.u32le(at: 16, offset: 132))
        XCTAssertGreaterThan(pathTableBytes, 0)
        XCTAssertEqual(Int(reader.u32be(at: 16, offset: 136)), pathTableBytes)

        // SVD / Joliet
        XCTAssertEqual(reader.byte(at: 17, offset: 0), 2)
        XCTAssertEqual(reader.ascii(at: 17, offset: 1, length: 5), "CD001")
        XCTAssertEqual(reader.byte(at: 17, offset: 88), UInt8(ascii: "%"))
        XCTAssertEqual(reader.byte(at: 17, offset: 89), UInt8(ascii: "/"))
        XCTAssertEqual(reader.byte(at: 17, offset: 90), UInt8(ascii: "E"))
        let jolietLabel = String(
            bytes: sink.bytes[(17 * 2048 + 40)..<(17 * 2048 + 72)].filter { $0 != 0 },
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(jolietLabel, "MY_DISC")

        // 终止符
        XCTAssertEqual(reader.byte(at: 18, offset: 0), 255)
        XCTAssertEqual(reader.ascii(at: 18, offset: 1, length: 5), "CD001")

        // 路径表（小端）：根目录 + 一个子目录？这里只有根目录，共 1 项。
        let pathTableLba = Int(reader.u32le(at: 16, offset: 140))
        XCTAssertEqual(reader.byte(at: pathTableLba, offset: 0), 1, "根路径表项标识符长度 = 1")
        XCTAssertEqual(reader.byte(at: pathTableLba, offset: 1), 0)
        let rootRecord = reader.rootRecord(descriptorLba: 16)
        let rootExtent = IsoReader.recordExtentLba(rootRecord)
        XCTAssertEqual(reader.u32le(at: pathTableLba, offset: 2), UInt32(rootExtent))
        XCTAssertEqual(reader.u16le(at: pathTableLba, offset: 6), 1)
    }

    func testUnicodeJolietNamesAndPrimaryNormalization() throws {
        let temp = try TemporaryDirectory()
        try temp.write("小图.txt", text: "图片")
        try temp.write("Mixed Name.TXT", text: "mixed")
        let entries = try FileTree.scan(root: temp.url)
        let plan = try Iso9660Writer.plan(
            entries: entries,
            volumeSectors: volumeSectors,
            volumeLabel: "光盘标签",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let sink = DataSequentialSink(capacity: volumeSectors * 2048)
        try Iso9660Writer.writeAll(plan, to: sink)
        let reader = IsoReader(sink.bytes)

        let rootPrimary = reader.rootRecord(descriptorLba: 16)
        let rootPrimaryLba = IsoReader.recordExtentLba(rootPrimary)
        let primaryRecords = reader.records(
            inDirectoryAt: rootPrimaryLba,
            byteCount: IsoReader.recordDataLength(rootPrimary)
        )
        let primaryNames = primaryRecords.map { String(bytes: $0.identifier, encoding: .ascii) ?? "" }
        XCTAssertTrue(primaryNames.contains("MIXED_NAME.TXT;1"), "主卷 8.3 风格名称：\(primaryNames)")
        XCTAssertTrue(primaryNames.contains { $0.hasPrefix("_") || $0.contains("TXT") })

        let rootJoliet = reader.rootRecord(descriptorLba: 17)
        let rootJolietLba = IsoReader.recordExtentLba(rootJoliet)
        let jolietRecords = reader.records(
            inDirectoryAt: rootJolietLba,
            byteCount: IsoReader.recordDataLength(rootJoliet)
        )
        let jolietNames = jolietRecords.map { record -> String in
            let identifier = IsoReader.recordIdentifier(record.record)
            let units = stride(from: 0, to: identifier.count - 1, by: 2).map {
                UInt16(identifier[$0]) << 8 | UInt16(identifier[$0 + 1])
            }
            return String(decoding: units, as: UTF16.self)
        }
        XCTAssertTrue(jolietNames.contains("小图.txt;1"), "Joliet 名称：\(jolietNames)")
        XCTAssertTrue(jolietNames.contains("Mixed Name.TXT;1"))

        // 主卷卷标被归一化成大写 ASCII；Joliet 卷标保留 UTF-16BE。
        let primaryLabel = reader.ascii(at: 16, offset: 40, length: 32)
        XCTAssertEqual(primaryLabel, "____" + String(repeating: " ", count: 28), "非 ASCII 卷标在主卷里被替换为下划线")
        let jolietLabelBytes = Array(sink.bytes[(17 * 2048 + 40)..<(17 * 2048 + 48)])
        XCTAssertEqual(jolietLabelBytes, Array("光盘标签".utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }))
    }

    func testDirectoryRecordsAndFileContent() throws {
        let temp = try TemporaryDirectory()
        let payload = Array("Hello, disc! 你好".utf8)
        try temp.write("hello.txt", bytes: payload)
        try temp.write("docs/readme.md", text: "readme contents")
        let entries = try FileTree.scan(root: temp.url)
        let plan = try Iso9660Writer.plan(
            entries: entries,
            volumeSectors: volumeSectors,
            volumeLabel: "DATA",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let sink = DataSequentialSink(capacity: volumeSectors * 2048)
        try Iso9660Writer.writeAll(plan, to: sink)
        let reader = IsoReader(sink.bytes)

        let rootRecord = reader.rootRecord(descriptorLba: 16)
        let rootLba = IsoReader.recordExtentLba(rootRecord)
        XCTAssertEqual(IsoReader.recordDataLength(rootRecord), plan.root.primaryDirectoryBytes)

        let rootRecords = reader.records(inDirectoryAt: rootLba, byteCount: IsoReader.recordDataLength(rootRecord))
        XCTAssertEqual(rootRecords.first?.identifier, [0])
        XCTAssertEqual(rootRecords.dropFirst().first?.identifier, [1])
        XCTAssertEqual(rootRecords.count, 4, ".; ..; DOCS; HELLO.TXT")

        guard let hello = reader.find(
            identifier: Array("HELLO.TXT;1".utf8),
            inDirectoryAt: rootLba,
            byteCount: IsoReader.recordDataLength(rootRecord)
        ) else {
            return XCTFail("根目录里找不到 HELLO.TXT;1")
        }
        let helloLba = IsoReader.recordExtentLba(hello)
        XCTAssertEqual(IsoReader.recordDataLength(hello), payload.count)
        XCTAssertEqual(reader.contents(atExtent: helloLba, length: payload.count), payload)

        guard let docs = reader.find(
            identifier: Array("DOCS".utf8),
            inDirectoryAt: rootLba,
            byteCount: IsoReader.recordDataLength(rootRecord)
        ) else {
            return XCTFail("根目录里找不到 DOCS")
        }
        let docsLba = IsoReader.recordExtentLba(docs)
        let docsRecords = reader.records(inDirectoryAt: docsLba, byteCount: IsoReader.recordDataLength(docs))
        XCTAssertEqual(docsRecords.count, 3, ".; ..; README.MD")
        guard let readme = reader.find(
            identifier: Array("README.MD;1".utf8),
            inDirectoryAt: docsLba,
            byteCount: IsoReader.recordDataLength(docs)
        ) else {
            return XCTFail("DOCS 里找不到 README.MD;1")
        }
        let readmeBytes = reader.contents(
            atExtent: IsoReader.recordExtentLba(readme),
            length: IsoReader.recordDataLength(readme)
        )
        XCTAssertEqual(readmeBytes, Array("readme contents".utf8))
    }

    func testDirectoryExtentSpansMultipleSectors() throws {
        let temp = try TemporaryDirectory()
        for index in 0..<120 {
            try temp.write(String(format: "file%03d.txt", index), text: "payload \(index)")
        }
        let entries = try FileTree.scan(root: temp.url)
        let volume = 256
        let plan = try Iso9660Writer.plan(
            entries: entries,
            volumeSectors: volume,
            volumeLabel: "MANY",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(plan.fileCount, 120)
        XCTAssertGreaterThan(plan.dataEndLbaExclusive, plan.metadataEndLbaExclusive)
        let sink = DataSequentialSink(capacity: volume * 2048)
        try Iso9660Writer.writeAll(plan, to: sink)
        let reader = IsoReader(sink.bytes)

        let rootRecord = reader.rootRecord(descriptorLba: 16)
        let rootLba = IsoReader.recordExtentLba(rootRecord)
        let rootBytes = IsoReader.recordDataLength(rootRecord)
        // 目录 extent 必须跨多个扇区，且记录不跨扇区边界。
        XCTAssertGreaterThan(rootBytes, 2048)
        let records = reader.records(inDirectoryAt: rootLba, byteCount: rootBytes)
        XCTAssertEqual(records.count, 122, ".; ..; 120 个文件")
        let names = Set(records.compactMap { record -> String? in
            guard record.identifier.count > 1 else { return nil }
            return String(bytes: record.identifier, encoding: .ascii)
        })
        XCTAssertEqual(names.count, 120)
        XCTAssertTrue(names.contains("FILE000.TXT;1"))
        XCTAssertTrue(names.contains("FILE119.TXT;1"))

        // 每个文件都能按记录里的 extent 读回自己的内容。
        for index in [0, 59, 119] {
            let name = String(format: "FILE%03d.TXT;1", index)
            guard let record = records.first(where: { $0.identifier == Array(name.utf8) })?.record else {
                return XCTFail("找不到 \(name)")
            }
            let content = reader.contents(
                atExtent: IsoReader.recordExtentLba(record),
                length: IsoReader.recordDataLength(record)
            )
            XCTAssertEqual(String(decoding: content, as: UTF8.self), "payload \(index)")
        }
    }

    func testOuterRingFilesLandAtVolumeEnd() throws {
        let temp = try TemporaryDirectory()
        let payload = Array("outer ring payload".utf8)
        try temp.write("hello.txt", bytes: payload)
        let entries = try FileTree.scan(root: temp.url)
        let plan = try Iso9660Writer.plan(
            entries: entries,
            volumeSectors: volumeSectors,
            volumeLabel: "OUTER",
            filesAtOuterRing: true,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let sink = DataSequentialSink(capacity: volumeSectors * 2048)
        try Iso9660Writer.writeAll(plan, to: sink)
        let reader = IsoReader(sink.bytes)
        let rootRecord = reader.rootRecord(descriptorLba: 16)
        let rootLba = IsoReader.recordExtentLba(rootRecord)
        guard let hello = reader.find(
            identifier: Array("HELLO.TXT;1".utf8),
            inDirectoryAt: rootLba,
            byteCount: IsoReader.recordDataLength(rootRecord)
        ) else {
            return XCTFail("根目录里找不到 HELLO.TXT;1")
        }
        let helloLba = IsoReader.recordExtentLba(hello)
        XCTAssertGreaterThanOrEqual(helloLba, plan.fileDataStartLba)
        XCTAssertEqual(reader.contents(atExtent: helloLba, length: payload.count), payload)
        // 元数据与文件之间的区域必须是零（调用方留作绘图区）。
        XCTAssertTrue(sink.bytes[(plan.metadataEndLbaExclusive * 2048)..<(plan.fileDataStartLba * 2048)].allSatisfy { $0 == 0 })
    }
}
