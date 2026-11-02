import DiscImageCore
import Foundation
import XCTest

/// 测试用临时目录（每个用例各自建、各自删）。
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiscImageDvdTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// 建一个文件（自动创建父目录），返回它的 URL。
    @discardableResult
    func write(_ relativePath: String, bytes: [UInt8]) throws -> URL {
        let fileURL = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(bytes).write(to: fileURL)
        return fileURL
    }

    @discardableResult
    func write(_ relativePath: String, text: String) throws -> URL {
        try write(relativePath, bytes: Array(text.utf8))
    }
}

/// 测试用的最小 ISO9660 解析器：只读 PVD/SVD 的根目录记录与目录 extent。
struct IsoReader {
    let bytes: [UInt8]
    static let sectorBytes = 2048

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    func sectorBytes(_ lba: Int) -> ArraySlice<UInt8> {
        let start = lba * Self.sectorBytes
        return bytes[start..<(start + Self.sectorBytes)]
    }

    func byte(at lba: Int, offset: Int) -> UInt8 {
        bytes[lba * Self.sectorBytes + offset]
    }

    func ascii(at lba: Int, offset: Int, length: Int) -> String {
        let start = lba * Self.sectorBytes + offset
        return String(bytes: bytes[start..<(start + length)], encoding: .ascii) ?? ""
    }

    func u16le(at lba: Int, offset: Int) -> UInt16 {
        let base = lba * Self.sectorBytes + offset
        return UInt16(bytes[base]) | UInt16(bytes[base + 1]) << 8
    }

    func u16be(at lba: Int, offset: Int) -> UInt16 {
        let base = lba * Self.sectorBytes + offset
        return UInt16(bytes[base]) << 8 | UInt16(bytes[base + 1])
    }

    func u32le(at lba: Int, offset: Int) -> UInt32 {
        let base = lba * Self.sectorBytes + offset
        return UInt32(bytes[base])
            | UInt32(bytes[base + 1]) << 8
            | UInt32(bytes[base + 2]) << 16
            | UInt32(bytes[base + 3]) << 24
    }

    func u32be(at lba: Int, offset: Int) -> UInt32 {
        let base = lba * Self.sectorBytes + offset
        return UInt32(bytes[base]) << 24
            | UInt32(bytes[base + 1]) << 16
            | UInt32(bytes[base + 2]) << 8
            | UInt32(bytes[base + 3])
    }

    /// 卷描述符里的根目录记录（PVD/SVD 第 156 字节起）。
    func rootRecord(descriptorLba: Int) -> [UInt8] {
        let base = descriptorLba * Self.sectorBytes + 156
        let length = Int(bytes[base])
        return Array(bytes[base..<(base + length)])
    }

    static func recordExtentLba(_ record: [UInt8]) -> Int {
        Int(UInt32(record[2]) | UInt32(record[3]) << 8 | UInt32(record[4]) << 16 | UInt32(record[5]) << 24)
    }

    static func recordDataLength(_ record: [UInt8]) -> Int {
        Int(UInt32(record[10]) | UInt32(record[11]) << 8 | UInt32(record[12]) << 16 | UInt32(record[13]) << 24)
    }

    static func recordIdentifier(_ record: [UInt8]) -> [UInt8] {
        let length = Int(record[32])
        return Array(record[33..<(33 + length)])
    }

    /// 解析一个目录 extent，返回 (identifier 字节, 记录)。
    func records(inDirectoryAt lba: Int, byteCount: Int) -> [(identifier: [UInt8], record: [UInt8])] {
        let extentStart = lba * Self.sectorBytes
        let extentEnd = extentStart + byteCount
        var result: [(identifier: [UInt8], record: [UInt8])] = []
        var offset = extentStart
        while offset < extentEnd {
            let length = Int(bytes[offset])
            if length == 0 {
                // 目录记录不跨扇区，零表示本扇区剩余字节是填充。
                offset = ((offset / Self.sectorBytes) + 1) * Self.sectorBytes
                continue
            }
            let record = Array(bytes[offset..<(offset + length)])
            result.append((Self.recordIdentifier(record), record))
            offset += length
        }
        return result
    }

    func find(identifier: [UInt8], inDirectoryAt lba: Int, byteCount: Int) -> [UInt8]? {
        records(inDirectoryAt: lba, byteCount: byteCount).first { $0.identifier == identifier }?.record
    }

    func contents(atExtent lba: Int, length: Int) -> [UInt8] {
        let start = lba * Self.sectorBytes
        return Array(bytes[start..<(start + length)])
    }
}
