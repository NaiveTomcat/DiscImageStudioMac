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
enum CdAudioTrackGenerator {
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
        let interleaver = CddaInterleaver(sink: sink, byteOrder: byteOrder)
        let throttle = CdProgressThrottle(minimumStep: 0.01)
        let totalBytes = parameters.totalBytes
        let interval = max(CdDiscParameters.bytesPerSector, totalBytes / 200)
        var nextProgress = interval

        throttle.emit(
            stage: "mapping",
            message: sampler.isNearestNeighbour ? "采样盘面（最近邻，源图已是纯黑白）" : "采样盘面（双线性）",
            fraction: 0,
            to: progress
        )

        for globalByte in 0..<totalBytes {
            if (globalByte & 0xFFF) == 0 {
                try cancellation?.check()
            }
            let gray = sampler.gray(atByte: globalByte)
            let value = CdToneMapping.map(
                gray: gray,
                tone: tone,
                sampleIndex: Int64(globalByte)   // 逻辑字节序号，不是文件位置
            )
            try interleaver.add(value)

            let completed = globalByte + 1
            if completed == totalBytes || completed >= nextProgress {
                let fraction = Double(completed) / Double(totalBytes)
                throttle.emit(
                    stage: "mapping",
                    message: String(format: "采样盘面并交织（%.1f%%）", fraction * 100),
                    fraction: fraction,
                    to: progress
                )
                nextProgress = completed + interval
            }
        }

        try interleaver.flush()
        return interleaver.bytesWritten
    }
}
