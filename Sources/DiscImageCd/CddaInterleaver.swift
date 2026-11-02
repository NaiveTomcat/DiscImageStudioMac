import DiscImageCore
import Foundation

/// CD-DA 的 112 帧环形延迟交织器。
///
/// 逐字节照搬源项目 `CddaInterleaver.cs` 的行为（它又来自 cdimage 的 `converter.cpp`）：
///
/// 1. 环形缓冲 `112 × 24 = 2688` 字节，`head` 从第 111 帧开始；
/// 2. 每读入一个逻辑字节，就按 `CddaInterleaveTable.delay(for: 帧内位置)` 放进环形缓冲；
/// 3. 每凑满一帧（24 字节），`head` 前进一帧，把该帧整块搬进当前扇区；
/// 4. 凑满 2352 字节就把扇区写到 sink；写之前在**扇区边界**上按需交换相邻字节
///    （WAV/流式 = 小端，RAW = 大端）。
///
/// 结果是：逻辑字节 `i` 落在音轨文件的 `i + fileOffsets[i % 24]`（72…2592 字节偏移）。
/// 延迟线在结尾还剩最后若干帧，因此尾部会丢 1318–1332 字节（不到一个扇区）。
///
/// 这个类只做字节重排，不碰 CIRC/EFM —— 源项目也没有。
final class CddaInterleaver {
    private let sink: SequentialSink
    private let littleEndian: Bool
    private var ring: [UInt8]
    private var sector: [UInt8]
    private var head = CddaInterleaveTable.framesPerCycle - 1
    private var inputPosition = 0
    private var sectorPosition = 0

    /// 已经写到 sink 的字节数。
    private(set) var bytesWritten = 0

    init(sink: SequentialSink, byteOrder: CdAudioByteOrder) {
        self.sink = sink
        self.littleEndian = byteOrder == .littleEndian
        self.ring = [UInt8](repeating: 0, count: CddaInterleaveTable.cycleBytes)
        self.sector = [UInt8](repeating: 0, count: CdDiscParameters.bytesPerSector)
    }

    /// 送入一个逻辑字节（音频样本字节，已按调色板映射）。
    func add(_ value: UInt8) throws {
        let delay = CddaInterleaveTable.delays[inputPosition]
        ring[mapIndex(head: head, position: delay)] = value
        inputPosition += 1
        if inputPosition < CddaInterleaveTable.bytesPerFrame {
            return
        }

        inputPosition = 0
        head += 1
        if head >= CddaInterleaveTable.framesPerCycle {
            head = 0
        }

        // 环形缓冲与音频扇区都是整帧存放，因此连 head 卷回 0 时这一帧也是连续的。
        let frameStart = head * CddaInterleaveTable.bytesPerFrame
        for offset in 0..<CddaInterleaveTable.bytesPerFrame {
            sector[sectorPosition + offset] = ring[frameStart + offset]
        }
        sectorPosition += CddaInterleaveTable.bytesPerFrame
        if sectorPosition == CdDiscParameters.bytesPerSector {
            try writeSector()
            sectorPosition = 0
        }
    }

    /// 把不满一个扇区的尾部补零写出（总字节数是扇区整数倍时什么也不做）。
    func flush() throws {
        guard sectorPosition > 0 else { return }
        for index in sectorPosition..<sector.count {
            sector[index] = 0
        }
        try writeSector()
        sectorPosition = 0
    }

    // MARK: - 内部

    private func writeSector() throws {
        if littleEndian {
            // 延迟交织补偿完成之后才交换字节：调换输入会改变图案（源项目的重影根因）。
            for index in stride(from: 0, to: CdDiscParameters.bytesPerSector, by: 2) {
                sector.swapAt(index, index + 1)
            }
        }
        try sink.write(sector)
        bytesWritten += CdDiscParameters.bytesPerSector
    }

    /// 环形缓冲下标：`head × 24 + delay`，越界时对 2688 取一次模
    /// （延迟绝对值 < 2688，一次加减足够）。
    private func mapIndex(head: Int, position: Int) -> Int {
        let modulus = CddaInterleaveTable.cycleBytes
        let value = head * CddaInterleaveTable.bytesPerFrame + position
        if value >= modulus { return value - modulus }
        if value < 0 { return value + modulus }
        return value
    }
}
