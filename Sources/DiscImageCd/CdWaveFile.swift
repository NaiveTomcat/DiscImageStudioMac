import DiscImageCore
import Foundation

/// WAV（CD-DA）容器与 CUE 旁写文件。
///
/// 格式照抄源项目 `CdWaveFile.cs`：44 字节 RIFF 头 + **小端** PCM，
/// 44100 Hz / 16 bit / 双声道（byte rate = 44100 × 2 × 2 = 176400）。
///
/// 文件长度 = 扇区数 × 2352 + 44 —— 文件头不占盘片音轨扇区，也不改变图案几何。
/// 与之配套的 `.cue` 是 UTF-8 **带 BOM**、CRLF 换行，`FILE "…wav" WAVE`：
/// ImgBurn / cdrdao 都按 WAVE 解释，不要写成 `BINARY`（那会让小端音频被当成大端）。
public enum CdWaveFile {
    /// RIFF 头长度。
    public static let headerBytes = 44
    public static let sampleRate = 44_100
    public static let channels = 2
    public static let bitsPerSample = 16
    /// 一帧（双声道 16 位）的字节数。
    public static let bytesPerFrame = 4
    /// 每秒字节数：44100 × 4。
    public static let byteRate = 176_400

    /// RIFF/WAV 的长度上限：RIFF 长度字段是 32 位，扣掉 `data` 之外的 36 字节；
    /// 再向下取整到 4 的倍数（一帧立体声样本 4 字节，半个样本没有意义）。
    public static let maximumAudioBytes = (Int(UInt32.max) - 36) / bytesPerFrame * bytesPerFrame

    // MARK: - 文件头

    /// 校验音频长度能否放进 RIFF。
    public static func validateLength(_ audioBytes: Int) throws {
        guard audioBytes > 0 else {
            throw DiscError.invalidGeometry("CD 音轨长度必须为正数（当前 \(audioBytes) 字节）")
        }
        guard audioBytes % bytesPerFrame == 0 else {
            throw DiscError.invalidGeometry("CD 音轨长度必须是 4 的整数倍（当前 \(audioBytes) 字节）")
        }
        guard audioBytes <= maximumAudioBytes else {
            throw DiscError.unsupported("音轨超出 RIFF/WAV 的长度上限（\(audioBytes) 字节）")
        }
    }

    /// 生成 44 字节 RIFF 头。
    public static func header(audioBytes: Int) throws -> [UInt8] {
        try validateLength(audioBytes)
        var header = [UInt8](repeating: 0, count: headerBytes)

        func putASCII(_ text: String, at offset: Int) {
            for (index, byte) in text.utf8.enumerated() {
                header[offset + index] = byte
            }
        }
        func put32(_ value: UInt32, at offset: Int) {
            header[offset] = UInt8(truncatingIfNeeded: value)
            header[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
            header[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
            header[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
        }
        func put16(_ value: UInt16, at offset: Int) {
            header[offset] = UInt8(truncatingIfNeeded: value)
            header[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }

        putASCII("RIFF", at: 0)
        put32(UInt32(audioBytes + 36), at: 4)
        putASCII("WAVE", at: 8)
        putASCII("fmt ", at: 12)
        put32(16, at: 16)                       // fmt 块长度
        put16(1, at: 20)                        // PCM
        put16(UInt16(channels), at: 22)
        put32(UInt32(sampleRate), at: 24)
        put32(UInt32(byteRate), at: 28)         // byte rate = 44100 × 2 × 2
        put16(UInt16(bytesPerFrame), at: 32)    // block align
        put16(UInt16(bitsPerSample), at: 34)
        putASCII("data", at: 36)
        put32(UInt32(audioBytes), at: 40)
        return header
    }

    /// 把 44 字节 RIFF 头写到前向 sink。
    public static func writeHeader(to sink: SequentialSink, audioBytes: Int) throws {
        try sink.write(try header(audioBytes: audioBytes))
    }

    // MARK: - 路径与 CUE

    /// `<base>.wav`。`base` 已经带 `.wav` 时原样返回。
    public static func wavURL(forBase base: URL) -> URL {
        base.pathExtension.lowercased() == "wav" ? base : base.appendingPathExtension("wav")
    }

    /// `<base>.cue`。
    public static func cueURL(forBase base: URL) -> URL {
        base.pathExtension.lowercased() == "cue" ? base : base.appendingPathExtension("cue")
    }

    /// CUE 文件的文本内容（UTF-8，`FILE` 指向 `<base>.wav` 的文件名）。
    public static func cueText(wavFileName: String) -> String {
        "FILE \"\(wavFileName)\" WAVE\r\n"
            + "  TRACK 01 AUDIO\r\n"
            + "    INDEX 01 00:00:00\r\n"
    }

    /// 在 WAV 文件旁写出同名 `.cue`（UTF-8 带 BOM、CRLF）。
    @discardableResult
    public static func writeCue(besideBaseURL base: URL) throws -> URL {
        let cueURL = cueURL(forBase: base)
        let wavURL = wavURL(forBase: base)
        var data = Data([0xEF, 0xBB, 0xBF])   // UTF-8 BOM：ImgBurn 靠它识别 Unicode 文件名
        data.append(Data(cueText(wavFileName: wavURL.lastPathComponent).utf8))
        do {
            try data.write(to: cueURL)
        } catch {
            throw DiscError.io("无法写入 CUE 文件：\(cueURL.lastPathComponent)")
        }
        return cueURL
    }
}
