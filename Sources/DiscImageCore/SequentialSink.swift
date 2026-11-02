import Foundation

/// 只能前向写的输出流。
///
/// 刻录链路是顺序流（不可 Seek），所以引擎一律奔着这个协议写；
/// 回退或重复写同一位置都算编程错误，直接抛 `DiscError.io`。
public protocol SequentialSink: AnyObject {
    /// 当前写指针（字节偏移）。
    var position: Int64 { get }
    /// 追加写入。实现必须一次性写完或抛错。
    func write(_ bytes: UnsafeRawBufferPointer) throws
    /// 用指定字节填充到绝对位置 `position`；已越过目标位置时抛错。
    func pad(to position: Int64, with byte: UInt8) throws
}

public extension SequentialSink {
    func write(_ bytes: [UInt8]) throws {
        if bytes.isEmpty { return }
        try bytes.withUnsafeBytes { try write($0) }
    }

    func write(_ data: Data) throws {
        if data.isEmpty { return }
        try data.withUnsafeBytes { try write($0) }
    }

    func write(_ byte: UInt8) throws {
        var value = byte
        try withUnsafeBytes(of: &value) { try write($0) }
    }

    /// 写入大端 16 位。
    func writeBigEndian(_ value: UInt16) throws {
        try write([UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// 写入大端 32 位。
    func writeBigEndian(_ value: UInt32) throws {
        try write([UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                   UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    /// 写入小端 16 位（WAV 用）。
    func writeLittleEndian(_ value: UInt16) throws {
        try write([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    /// 写入小端 32 位（WAV 用）。
    func writeLittleEndian(_ value: UInt32) throws {
        try write([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                   UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }
}

/// 写入文件的前向 sink（POSIX `open`/`write`，失败信息带 errno 说明）。
public final class FileSequentialSink: SequentialSink {
    private var descriptor: Int32
    private var cursor: Int64
    private let path: String
    private var closed = false

    /// - Parameters:
    ///   - url: 目标文件
    ///   - truncate: 是否清空已有内容（导出时 true）
    public init(url: URL, truncate: Bool = true) throws {
        path = url.path
        descriptor = open(path, O_WRONLY | O_CREAT | (truncate ? O_TRUNC : 0), 0o644)
        guard descriptor >= 0 else {
            throw DiscError.io("无法写入 \(url.lastPathComponent)：\(String(cString: strerror(errno)))")
        }
        cursor = 0
    }

    deinit {
        if !closed { Darwin.close(descriptor) }
    }

    public var position: Int64 { cursor }

    public func write(_ bytes: UnsafeRawBufferPointer) throws {
        guard !closed else { throw DiscError.io("文件已关闭：\(path)") }
        guard let base = bytes.baseAddress, bytes.count > 0 else { return }
        var written = 0
        while written < bytes.count {
            let result = rawWrite(descriptor, base.advanced(by: written), bytes.count - written)
            if result < 0 {
                if errno == EINTR { continue }
                throw DiscError.io("写入失败（\(path)）：\(String(cString: strerror(errno)))")
            }
            written += result
        }
        cursor += Int64(bytes.count)
    }

    public func pad(to target: Int64, with byte: UInt8) throws {
        guard target >= cursor else {
            throw DiscError.io("不能回退写入（当前位置 \(cursor)，目标 \(target)）")
        }
        let filler = [UInt8](repeating: byte, count: 64 * 1024)
        while cursor < target {
            let remaining = Int(min(Int64(filler.count), target - cursor))
            try filler.withUnsafeBytes { try write(UnsafeRawBufferPointer(rebasing: $0[0..<remaining])) }
        }
    }

    /// 显式关闭并落盘（用于导出完成后立刻被 `hdiutil` 读到）。
    public func close() throws {
        guard !closed else { return }
        closed = true
        if Darwin.close(descriptor) != 0 {
            throw DiscError.io("关闭文件失败（\(path)）：\(String(cString: strerror(errno)))")
        }
    }

    private func rawWrite(_ fd: Int32, _ pointer: UnsafeRawPointer, _ count: Int) -> Int {
        Darwin.write(fd, pointer, count)
    }
}

/// 内存 sink：测试与预览用。`bytes` 即完整输出。
public final class DataSequentialSink: SequentialSink {
    public private(set) var bytes: [UInt8]

    public init(capacity: Int = 0) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    public var position: Int64 { Int64(bytes.count) }

    public func write(_ buffer: UnsafeRawBufferPointer) throws {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return }
        bytes.append(contentsOf: UnsafeRawBufferPointer(start: base, count: buffer.count))
    }

    public func pad(to target: Int64, with byte: UInt8) throws {
        guard target >= position else {
            throw DiscError.io("不能回退写入（当前位置 \(position)，目标 \(target)）")
        }
        let count = Int(target - position)
        if count > 0 {
            bytes.append(contentsOf: [UInt8](repeating: byte, count: count))
        }
    }

    public func writeToFile(_ url: URL) throws {
        try Data(bytes).write(to: url, options: .atomic)
    }
}

/// 丢弃输出的 sink：只跑编码、不落盘（用于「预览」与性能测量）。
public final class NullSequentialSink: SequentialSink {
    public private(set) var position: Int64 = 0

    public init() {}

    public func write(_ bytes: UnsafeRawBufferPointer) throws {
        position += Int64(bytes.count)
    }

    public func pad(to target: Int64, with byte: UInt8) throws {
        guard target >= position else {
            throw DiscError.io("不能回退写入（当前位置 \(position)，目标 \(target)）")
        }
        position = target
    }
}
