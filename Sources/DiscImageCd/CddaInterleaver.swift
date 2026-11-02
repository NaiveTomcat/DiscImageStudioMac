import DiscImageCore
import Foundation

/// CD-DA 的 112 帧环形延迟交织器。
///
/// 逐字节照搬源项目 `CddaInterleaver.cs` 的行为（它又来自 cdimage 的 `converter.cpp`）：
///
/// 1. 环形缓冲 `112 × 24 = 2688` 字节，`head` 从第 111 帧开始；
/// 2. 每读入一个逻辑字节，就按 `CddaInterleaveTable.delay(for: 帧内位置)` 放进环形缓冲；
/// 3. 每凑满一帧（24 字节），`head` 前进一帧，把该帧整块搬进输出缓冲；
/// 4. 攒够若干整扇区就整批写到 sink；写之前在**扇区边界**上按需交换相邻字节
///    （WAV/流式 = 小端，RAW = 大端）。
///
/// 结果是：逻辑字节 `i` 落在音轨文件的 `i + fileOffsets[i % 24]`（72…2592 字节偏移）。
/// 延迟线在结尾还剩最后若干帧，因此尾部会丢 1318–1332 字节（不到一个扇区）。
///
/// 这个类只做字节重排，不碰 CIRC/EFM —— 源项目也没有。
///
/// 实现上用裸缓冲区代替 `[UInt8]`：环形缓冲、延迟表、批量输出各一份手工分配内存，
/// 热点循环里没有边界检查；输出按 `sectorsPerBatch` 个扇区攒批，减小写系统调用次数。
/// 语义与逐字节版本完全一致（`add(_ byte:)` 与 `add(_ bytes:)` 等价，有测试对拍）。
final class CddaInterleaver {
    /// 一次写盘的扇区数（32 × 2352 = 73.5 KiB）。
    static let sectorsPerBatch = 32

    private let sink: SequentialSink
    private let littleEndian: Bool
    private let ring: UnsafeMutablePointer<UInt8>
    private let output: UnsafeMutablePointer<UInt8>
    private let delays: UnsafeMutablePointer<Int>
    private let outputCapacity: Int
    private var fill = 0
    private var head = CddaInterleaveTable.framesPerCycle - 1
    private var inputPosition = 0

    /// 已经写到 sink 的字节数（含 flush 时补齐的扇区尾部）。
    private(set) var bytesWritten = 0

    init(sink: SequentialSink, byteOrder: CdAudioByteOrder) {
        self.sink = sink
        self.littleEndian = byteOrder == .littleEndian
        self.outputCapacity = CdDiscParameters.bytesPerSector * Self.sectorsPerBatch

        let ringCount = CddaInterleaveTable.cycleBytes
        ring = UnsafeMutablePointer<UInt8>.allocate(capacity: ringCount)
        ring.initialize(repeating: 0, count: ringCount)

        output = UnsafeMutablePointer<UInt8>.allocate(capacity: outputCapacity)
        output.initialize(repeating: 0, count: outputCapacity)

        let frameBytes = CddaInterleaveTable.bytesPerFrame
        delays = UnsafeMutablePointer<Int>.allocate(capacity: frameBytes)
        for position in 0..<frameBytes {
            delays[position] = CddaInterleaveTable.delays[position]
        }
    }

    deinit {
        ring.deallocate()
        output.deallocate()
        delays.deallocate()
    }

    // MARK: - 输入

    /// 送入一个逻辑字节（音频样本字节，已按调色板映射）。
    func add(_ value: UInt8) throws {
        ring[mapIndex(head: head, position: delays[inputPosition])] = value
        inputPosition += 1
        if inputPosition < CddaInterleaveTable.bytesPerFrame {
            return
        }
        inputPosition = 0
        advanceHead()
        try emitFrame()
    }

    /// 批量送入逻辑字节（并行绘制产出的整块）。
    func add(_ bytes: UnsafeBufferPointer<UInt8>) throws {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        let frameBytes = CddaInterleaveTable.bytesPerFrame
        var offset = 0

        // 先补齐当前未完成的帧（块边界不一定落在帧边界上）。
        if inputPosition != 0 {
            while inputPosition < frameBytes && offset < bytes.count {
                ring[mapIndex(head: head, position: delays[inputPosition])] = base[offset]
                inputPosition += 1
                offset += 1
            }
            if inputPosition == frameBytes {
                inputPosition = 0
                advanceHead()
                try emitFrame()
            }
            if offset >= bytes.count { return }
        }

        // 整帧快路径。
        while offset + frameBytes <= bytes.count {
            let frameStart = head * frameBytes
            var position = 0
            while position < frameBytes {
                var index = frameStart + delays[position]
                if index >= CddaInterleaveTable.cycleBytes {
                    index -= CddaInterleaveTable.cycleBytes
                } else if index < 0 {
                    index += CddaInterleaveTable.cycleBytes
                }
                ring[index] = base[offset + position]
                position += 1
            }
            offset += frameBytes
            advanceHead()
            try emitFrame()
        }

        // 末尾不足一帧的部分。
        while offset < bytes.count {
            ring[mapIndex(head: head, position: delays[inputPosition])] = base[offset]
            inputPosition += 1
            offset += 1
        }
    }

    /// 把不满一个扇区的尾部补零写出（总字节数是扇区整数倍时什么也不做）。
    func flush() throws {
        let sectorBytes = CdDiscParameters.bytesPerSector
        if fill % sectorBytes != 0 {
            let padded = (fill / sectorBytes + 1) * sectorBytes
            for index in fill..<padded {
                output[index] = 0
            }
            fill = padded
        }
        try flushOutput()
    }

    // MARK: - 内部

    @inline(__always)
    private func advanceHead() {
        head += 1
        if head >= CddaInterleaveTable.framesPerCycle {
            head = 0
        }
    }

    /// 把当前 `head` 指向的整帧搬进输出缓冲；小端时在这里顺带交换相邻字节。
    ///
    /// 帧长 24 是偶数、帧在扇区里的起点恒为 4 的倍数，所以「逐帧交换」与
    /// 「整扇区交换」逐字节等价（源项目的重影修复就是在这个边界上做的交换）。
    @inline(__always)
    private func emitFrame() throws {
        let frameStart = head * CddaInterleaveTable.bytesPerFrame
        if littleEndian {
            var position = 0
            while position < CddaInterleaveTable.bytesPerFrame {
                output[fill + position] = ring[frameStart + position + 1]
                output[fill + position + 1] = ring[frameStart + position]
                position += 2
            }
        } else {
            var position = 0
            while position < CddaInterleaveTable.bytesPerFrame {
                output[fill + position] = ring[frameStart + position]
                position += 1
            }
        }
        fill += CddaInterleaveTable.bytesPerFrame
        if fill == outputCapacity {
            try flushOutput()
        }
    }

    private func flushOutput() throws {
        guard fill > 0 else { return }
        try sink.write(UnsafeRawBufferPointer(start: output, count: fill))
        bytesWritten += fill
        fill = 0
    }

    /// 环形缓冲下标：`head × 24 + delay`，越界时对 2688 取一次模
    /// （延迟绝对值 < 2688，一次加减足够）。
    @inline(__always)
    private func mapIndex(head: Int, position: Int) -> Int {
        let value = head * CddaInterleaveTable.bytesPerFrame + position
        if value >= CddaInterleaveTable.cycleBytes {
            return value - CddaInterleaveTable.cycleBytes
        }
        if value < 0 {
            return value + CddaInterleaveTable.cycleBytes
        }
        return value
    }
}
