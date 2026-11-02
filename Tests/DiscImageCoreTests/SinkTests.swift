import Foundation
import XCTest
@testable import DiscImageCore

final class SinkTests: XCTestCase {

    func testDataSinkAppendsAndPads() throws {
        let sink = DataSequentialSink()
        try sink.write([0x01, 0x02, 0x03])
        XCTAssertEqual(sink.position, 3)
        try sink.pad(to: 8, with: 0xAA)
        XCTAssertEqual(sink.position, 8)
        XCTAssertEqual(sink.bytes, [0x01, 0x02, 0x03, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA])
    }

    func testDataSinkRefusesRewind() throws {
        let sink = DataSequentialSink()
        try sink.write([1, 2, 3, 4])
        XCTAssertThrowsError(try sink.pad(to: 2, with: 0))
    }

    func testEndianHelpers() throws {
        let sink = DataSequentialSink()
        try sink.writeBigEndian(UInt32(0x0012_3456))
        try sink.writeLittleEndian(UInt32(0x0012_3456))
        try sink.writeBigEndian(UInt16(0xBEEF))
        try sink.writeLittleEndian(UInt16(0xBEEF))
        XCTAssertEqual(sink.bytes, [
            0x00, 0x12, 0x34, 0x56,
            0x56, 0x34, 0x12, 0x00,
            0xBE, 0xEF,
            0xEF, 0xBE,
        ])
    }

    func testNullSinkTracksPosition() throws {
        let sink = NullSequentialSink()
        try sink.write([UInt8](repeating: 0, count: 1000))
        try sink.pad(to: 4096, with: 0)
        XCTAssertEqual(sink.position, 4096)
        XCTAssertThrowsError(try sink.pad(to: 100, with: 0))
    }

    func testFileSinkWritesAndCloses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiscImageCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("out.bin")
        let sink = try FileSequentialSink(url: url)
        try sink.write([0xDE, 0xAD, 0xBE, 0xEF])
        try sink.pad(to: 16, with: 0x00)
        try sink.close()

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 16)
        XCTAssertEqual([UInt8](data.prefix(4)), [0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual([UInt8](data.suffix(12)), [UInt8](repeating: 0, count: 12))
    }

    func testFileSinkTruncatesExistingFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiscImageCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("out.bin")
        try Data([UInt8](repeating: 0xFF, count: 64)).write(to: url)

        let sink = try FileSequentialSink(url: url)
        try sink.write([0x00])
        try sink.close()

        XCTAssertEqual(try Data(contentsOf: url).count, 1)
    }
}
