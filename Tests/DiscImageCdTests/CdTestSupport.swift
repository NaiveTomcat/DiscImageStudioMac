import DiscImageCore
import Foundation
import XCTest

@testable import DiscImageCd

/// 工作包 B 测试的公共夹具。
///
/// 规模约定（HANDOFF §6.B / task-2）：一律用**局部扇区**做断言，绝不生成整张 800 MB。
enum CdTestSupport {
    /// 端到端测试用的扇区数：8 扇区 = 18,816 字节，够覆盖一个完整延迟线周期以上。
    static let smallSectors = 8

    static func parameters(
        sectors: Int = smallSectors,
        innerRadiusMm: Double = 24.5,
        outerRadiusMm: Double = 56.8
    ) -> CdDiscParameters {
        CdDiscParameters(
            innerRadiusMm: innerRadiusMm,
            outerRadiusMm: outerRadiusMm,
            sectors: sectors
        )
    }

    static func geometry(sectors: Int = smallSectors) -> DiscGeometry {
        DiscGeometry(
            family: .cd,
            innerRadiusMm: 24.5,
            outerRadiusMm: 56.8,
            sectors: sectors,
            linearVelocityMmPerSecond: 1200
        )
    }

    /// 非对称测试图：左半横向渐变、右半竖条纹、中间挖一个方孔。
    /// 不是纯黑白，所以采样走双线性（要测最近邻时用 `binaryImage`）。
    static func testImage(width: Int = 64, height: Int = 64) -> RasterImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8
                if (24..<40).contains(x) && (24..<40).contains(y) {
                    value = 0
                } else if x < width / 2 {
                    value = UInt8(x * 4 % 256)
                } else if (y / 4) % 2 == 0 {
                    value = 0
                } else {
                    value = 220
                }
                let offset = (y * width + x) * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 255
            }
        }
        return RasterImage(width: width, height: height, pixels: pixels)
    }

    /// 纯黑白（不透明）测试图：采样应走最近邻。
    static func binaryImage(width: Int = 32, height: Int = 32) -> RasterImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8 = x < width / 2 ? 0 : 255
                let offset = (y * width + x) * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 255
            }
        }
        return RasterImage(width: width, height: height, pixels: pixels)
    }

    /// 工作区内的临时目录（`.build-cd/test-scratch/<uuid>`）。
    ///
    /// 不使用系统临时目录：DSH 沙箱只保证工作区可写。
    static func scratchDirectory() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build-cd", isDirectory: true)
            .appendingPathComponent("test-scratch", isDirectory: true)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// 造一个最小的随盘文件夹：两个文件 + 一个子目录（覆盖目录记录与路径表）。
    static func makeDataFolder(at directory: URL) throws {
        let fileManager = FileManager.default
        try Data("hello from disc image studio\n".utf8)
            .write(to: directory.appendingPathComponent("readme.txt"))
        let subdirectory = directory.appendingPathComponent("pictures")
        try fileManager.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 3_000)
            .write(to: subdirectory.appendingPathComponent("tile.bin"))
    }

    /// 小端 32 位读取（断言 WAV 头用）。
    static func littleEndian32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    /// 小端 16 位读取。
    static func littleEndian16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    static func ascii(_ bytes: [UInt8], at offset: Int, count: Int) -> String {
        String(decoding: bytes[offset..<(offset + count)], as: UTF8.self)
    }
}
