import Foundation

/// CD 音频样本的字节序。
///
/// 源项目的结论（`docs/CD_AUDIO_COMPATIBILITY.md`）：
///
/// - **RAW 输出 = 大端**：`cdrecord -audio` 的默认约定，不要额外加 `-swab`；
/// - **WAV / 流式刻录 = 小端**：WAV 的 PCM data 区与 IMAPI 的 AUDIO 扇区都是小端；
/// - 交换发生在**延迟交织之后的 2352 字节扇区边界**上。先交换再交织会把属于不同
///   延迟位置的字节交叉送进编码链，画面上就会出现两组轮廓（源项目排查过的重影）。
public enum CdAudioByteOrder: String, Sendable, CaseIterable {
    case bigEndian
    case littleEndian

    /// 每个 16 位立体声样本的字节数。
    public static let bytesPerSample = 2
}
