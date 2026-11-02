import DiscImageCore
import Foundation
import XCTest

@testable import DiscImageCd

/// WAV / CUE 容器格式（task-2 第 4 条）：44 字节 RIFF 头、小端 PCM、
/// 44.1 kHz / 16 bit / 双声道、byte rate = 44100×2×2；旁写同名 `.cue`。
final class CdWaveFileTests: XCTestCase {

    func testHeaderLayoutFieldByField() throws {
        let audioBytes = 8 * CdDiscParameters.bytesPerSector   // 18,816
        let header = try CdWaveFile.header(audioBytes: audioBytes)

        XCTAssertEqual(header.count, 44)
        XCTAssertEqual(CdWaveFile.headerBytes, 44)
        XCTAssertEqual(CdWaveFile.sampleRate, 44_100)
        XCTAssertEqual(CdWaveFile.channels, 2)
        XCTAssertEqual(CdWaveFile.bitsPerSample, 16)

        XCTAssertEqual(CdTestSupport.ascii(header, at: 0, count: 4), "RIFF")
        XCTAssertEqual(CdTestSupport.littleEndian32(header, at: 4), UInt32(audioBytes + 36))
        XCTAssertEqual(CdTestSupport.ascii(header, at: 8, count: 4), "WAVE")
        XCTAssertEqual(CdTestSupport.ascii(header, at: 12, count: 4), "fmt ")
        XCTAssertEqual(CdTestSupport.littleEndian32(header, at: 16), 16)      // fmt 块长度
        XCTAssertEqual(CdTestSupport.littleEndian16(header, at: 20), 1)       // PCM
        XCTAssertEqual(CdTestSupport.littleEndian16(header, at: 22), 2)       // 双声道
        XCTAssertEqual(CdTestSupport.littleEndian32(header, at: 24), 44_100)  // 采样率
        XCTAssertEqual(CdTestSupport.littleEndian32(header, at: 28), 176_400) // byte rate
        XCTAssertEqual(CdTestSupport.littleEndian32(header, at: 28), 44_100 * 2 * 2)
        XCTAssertEqual(CdTestSupport.littleEndian16(header, at: 32), 4)       // block align
        XCTAssertEqual(CdTestSupport.littleEndian16(header, at: 34), 16)      // 位深
        XCTAssertEqual(CdTestSupport.ascii(header, at: 36, count: 4), "data")
        XCTAssertEqual(CdTestSupport.littleEndian32(header, at: 40), UInt32(audioBytes))
        // 小端：RIFF 长度 18,852（0x49A4）应写成 A4 49 00 00。
        XCTAssertEqual(Array(header[4..<8]), [0xA4, 0x49, 0x00, 0x00])
    }

    func testHeaderRejectsInvalidLengths() {
        XCTAssertThrowsError(try CdWaveFile.header(audioBytes: 0))
        XCTAssertThrowsError(try CdWaveFile.header(audioBytes: 2_350))          // 不是 4 的倍数
        XCTAssertThrowsError(try CdWaveFile.header(audioBytes: Int(UInt32.max))) // 超出 RIFF 上限
        XCTAssertNoThrow(try CdWaveFile.header(audioBytes: CdWaveFile.maximumAudioBytes))
    }

    func testCueTextReferencesTheWaveFile() {
        let text = CdWaveFile.cueText(wavFileName: "cd-track.wav")
        XCTAssertTrue(text.hasPrefix("FILE \"cd-track.wav\" WAVE\r\n"))
        XCTAssertTrue(text.contains("TRACK 01 AUDIO"))
        XCTAssertTrue(text.contains("INDEX 01 00:00:00"))
        // CUE 必须是 CRLF，`FILE … WAVE` 不能写成 BINARY。
        XCTAssertTrue(text.hasSuffix("\r\n"))
        XCTAssertFalse(text.contains("BINARY"))
    }

    func testCueFileIsUTF8WithBOM() throws {
        let directory = try CdTestSupport.scratchDirectory()
        defer { CdTestSupport.remove(directory) }

        let base = directory.appendingPathComponent("我的 音轨")
        let cueURL = try CdWaveFile.writeCue(besideBaseURL: base)

        XCTAssertEqual(cueURL, directory.appendingPathComponent("我的 音轨.cue"))
        let data = try Data(contentsOf: cueURL)
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        XCTAssertEqual(text, "FILE \"我的 音轨.wav\" WAVE\r\n  TRACK 01 AUDIO\r\n    INDEX 01 00:00:00\r\n")
    }

    func testPathHelpers() {
        let base = URL(fileURLWithPath: "/tmp/cd-track")
        XCTAssertEqual(CdWaveFile.wavURL(forBase: base).lastPathComponent, "cd-track.wav")
        XCTAssertEqual(CdWaveFile.cueURL(forBase: base).lastPathComponent, "cd-track.cue")
        let alreadyWav = URL(fileURLWithPath: "/tmp/cd-track.wav")
        XCTAssertEqual(CdWaveFile.wavURL(forBase: alreadyWav).lastPathComponent, "cd-track.wav")
    }
}
