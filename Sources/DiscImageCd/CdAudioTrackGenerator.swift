import DiscImageCore
import Foundation

/// 生成一条 CD-DA 音轨（2352 字节扇区的字节流）。
///
/// 链路（与 HANDOFF §2.1 的 CD 段一致）：
///
/// ```
/// 图片 → (r, θ) → 逻辑字节序号 → 灰度 → ToneProfile → 调色板字节
///      → 112 帧环形延迟交织 → 2352 字节扇区 → sink
/// ```
///
/// **没有** CIRC 纠错、**没有** EFM 调制：源项目本来就只有字节级延迟重排。
///
/// 采样与交织解耦成两段：
/// - `produce` 按块并行算原始字节（块内只依赖逻辑字节序号，块间无状态）；
/// - `consume` 单线程按序喂给 `CddaInterleaver`（交织依赖全局顺序），再写 sink。
///
/// 块大小取 32 个扇区（2352 × 32 = 73.5 KiB）的整数倍，`chunkSize` 决定同时
/// 在飞多少块（内存上界 = chunkSize × 块大小）；`DISCI_MAX_WORKERS=1` 时
/// `ParallelPipeline` 退化成串行，输出与并行逐字节相同。
enum CdAudioTrackGenerator {
    /// 单块字节数：32 个扇区，正好是交织器一次批量写盘的粒度。
    static let blockBytes = CdDiscParameters.bytesPerSector * CddaInterleaver.sectorsPerBatch

    /// - Returns: 写入 sink 的音频字节数（恒为 `sectors × 2352`）。
    @discardableResult
    static func writeTrack(
        image: RasterImage,
        parameters: CdDiscParameters,
        tone: ToneProfile,
        byteOrder: CdAudioByteOrder,
        to sink: SequentialSink,
        progress: (DiscProgress) -> Void,
        cancellation: CancellationFlag?
    ) throws -> Int {
        let sampler = CdImageSampler(image: image, parameters: parameters)
        let blockSampler = CdBlockSampler(sampler: sampler, tone: tone)
        let interleaver = CddaInterleaver(sink: sink, byteOrder: byteOrder)
        let throttle = CdProgressThrottle(minimumStep: 0.01)
        let totalBytes = parameters.totalBytes
        let blockCount = (totalBytes + blockBytes - 1) / blockBytes

        throttle.emit(
            stage: "mapping",
            message: sampler.isNearestNeighbour ? "采样盘面（最近邻，源图已是纯黑白）" : "采样盘面（双线性）",
            fraction: 0,
            to: progress
        )

        var completed = 0
        try ParallelPipeline.run(
            count: blockCount,
            chunkSize: 32,
            workers: ParallelPipeline.defaultWorkers,
            cancellation: cancellation,
            produce: { index in
                let start = index * blockBytes
                let count = min(blockBytes, totalBytes - start)
                var buffer = [UInt8](repeating: 0, count: count)
                buffer.withUnsafeMutableBufferPointer { pointer in
                    guard let base = pointer.baseAddress else { return }
                    blockSampler.fill(start: start, count: count, into: base)
                }
                return buffer
            },
            consume: { blocks in
                for block in blocks {
                    try block.withUnsafeBufferPointer { try interleaver.add($0) }
                    completed += block.count
                    let fraction = Double(completed) / Double(totalBytes)
                    throttle.emit(
                        stage: "mapping",
                        message: String(format: "采样盘面并交织（%.1f%%）", fraction * 100),
                        fraction: fraction,
                        to: progress
                    )
                }
            }
        )

        try interleaver.flush()
        return interleaver.bytesWritten
    }
}
