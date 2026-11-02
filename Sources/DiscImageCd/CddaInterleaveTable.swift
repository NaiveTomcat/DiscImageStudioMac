import Foundation

/// CD-DA 的 CIRC 延迟表（`28 × D`，D = 4）。
///
/// 这是整条 CD 链路里**唯一**与 CIRC 有关的东西：源项目没有做 CIRC 纠错编码，
/// 只借用了 CIRC 的 28 帧延迟线形状，把音频字节在文件里做一次**可逆的字节重排**
/// （`CddaInterleaver`）。表本身的出处是 arduinocelentano/cdimage 的 `converter.cpp`，
/// 经源项目 `CddaInterleaveTable.cs` 移植；下标与移位都原样保留，不要"优化"。
///
/// 语义：
///
/// - 每帧 24 音频字节，延迟线 112 帧（= 28 × 4），共 2688 字节；
/// - 逻辑字节 `i`（帧内位置 `i % 24`）落在文件索引 `i + fileOffsets[i % 24]`；
/// - 偏移范围 **72…2592 字节**（帧延迟 + 帧内列旋转之和），即读回预览最多需要
///   2592 字节的前视窗口；
/// - 文件结尾处延迟线里还剩最后若干帧，这些逻辑字节没有写出（整盘 1318–1332 字节，
///   不到一个扇区），读回时只能留空。
public enum CddaInterleaveTable {
    /// CIRC 的深度 D。4 是 CD-DA 的实际取值。
    public static let depth = 4
    /// 延迟线帧数 = 28 × D = 112。
    public static let framesPerCycle = 28 * depth
    /// 每帧音频字节数。
    public static let bytesPerFrame = 24

    /// 帧内每个位置的延迟（以字节为单位，负值表示"往环形缓冲的前面放"）。
    public static let delays: [Int] = buildDelays()

    /// 帧内每个位置对应的文件偏移：逻辑字节 `i` 落在文件索引 `i + fileOffsets[i % 24]`。
    public static let fileOffsets: [Int] = buildFileOffsets()

    /// 延迟线的字节数（112 × 24 = 2688）。
    public static var cycleBytes: Int { framesPerCycle * bytesPerFrame }

    /// 帧内位置处的延迟。
    public static func delay(for position: Int) -> Int {
        delays[normalizedPosition(position)]
    }

    /// 帧内位置处的文件偏移。
    public static func fileOffset(for position: Int) -> Int {
        fileOffsets[normalizedPosition(position)]
    }

    /// 逻辑字节序号对应的文件偏移（`i + offset` 就是它在音轨文件里的位置）。
    public static func fileOffset(forLogicalByte index: Int) -> Int {
        fileOffsets[normalizedPosition(index % bytesPerFrame)]
    }

    /// 最小文件偏移（应为 72 字节）。
    public static var minimumFileOffset: Int { fileOffsets.min() ?? 0 }
    /// 最大文件偏移（应为 2592 字节），也就是读回预览需要的前视窗口。
    public static var maximumFileOffset: Int { fileOffsets.max() ?? 0 }

    /// 逻辑字节 `i` 在文件里的索引。超出文件长度的那些逻辑字节就是尾部被丢弃的部分。
    public static func fileIndex(forLogicalByte index: Int) -> Int {
        index + fileOffset(forLogicalByte: index)
    }

    /// 给定音轨总字节数，返回延迟线在尾部丢掉的逻辑字节数。
    ///
    /// 源项目实测口径：整盘 1318–1332 字节（不到一个扇区）。生成器写出的音轨长度
    /// 恒为 `sectors × 2352`，所以正常几何下这个值就是 1332。
    public static func droppedTailByteCount(totalBytes: Int) -> Int {
        guard totalBytes > 0 else { return 0 }
        // 只有最后 maximumFileOffset 个逻辑字节可能落到文件长度之外，无需扫全盘。
        var dropped = 0
        for index in max(0, totalBytes - maximumFileOffset)..<totalBytes
        where fileIndex(forLogicalByte: index) >= totalBytes {
            dropped += 1
        }
        return dropped
    }

    // MARK: - 建表（逐行照抄源项目，不要改成闭式解）

    private static func normalizedPosition(_ position: Int) -> Int {
        let wrapped = position % bytesPerFrame
        return wrapped < 0 ? wrapped + bytesPerFrame : wrapped
    }

    private static func buildDelays() -> [Int] {
        let k0Even = [0, 8, 16, 2, 10, 18]
        let k0Odd = [4, 12, 20, 6, 14, 22]
        var delays = [Int](repeating: 0, count: bytesPerFrame)

        for index in 0..<12 {
            let odd = (index & 1) != 0
            delays[index] = (odd ? 1 : 0)
                - bytesPerFrame * (index * depth + (odd ? 2 : 3))
                + k0Even[index / 2]
        }
        for index in 12..<bytesPerFrame {
            let odd = ((index - 12) & 1) != 0
            delays[index] = (odd ? 1 : 0)
                - bytesPerFrame * ((index + 4) * depth + (odd ? 0 : 1))
                + k0Odd[(index - 12) / 2]
        }
        return delays
    }

    /// 帧延迟表的逆：交织器把逻辑帧前推 `(framesPerCycle − 1 − encoderDelay)` 帧，
    /// 并把帧内字节挪到延迟列上，两者相加就是这里的偏移。
    private static func buildFileOffsets() -> [Int] {
        var offsets = [Int](repeating: 0, count: bytesPerFrame)
        for position in 0..<bytesPerFrame {
            let delay = delays[position]
            let column = ((delay % bytesPerFrame) + bytesPerFrame) % bytesPerFrame
            let frameDelay = (column - delay) / bytesPerFrame
            offsets[position] = bytesPerFrame * (framesPerCycle - 1)
                - bytesPerFrame * frameDelay
                + column
                - position
        }
        return offsets
    }
}
