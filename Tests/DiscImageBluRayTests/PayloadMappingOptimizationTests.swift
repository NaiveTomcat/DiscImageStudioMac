import Darwin
import XCTest
import DiscImageCore
@testable import DiscImageBluRay

/// 取样加速与并行生成的回归：优化后的输出必须与参考实现逐字节一致。
///
/// 这两个测试是 task-6 的硬约束：`artifacts/reference/bd1024.iso` 的 sha256 不能变，
/// 并行与串行必须写出相同字节。CLI 级 sha 校验在 release 构建上手工执行（见汇报）。
final class PayloadMappingOptimizationTests: XCTestCase {
    // MARK: - 查找表插值 vs 逐字节精确取样

    func testFastSamplingMatchesExactReference() throws {
        let geometries: [(sectors: Int, inner: Double, outer: Double)] = [
            (1024, 24, 40),
            (16_384, 24, 50),
        ]
        let images: [(String, RasterImage)] = [
            ("gradient", makeGradientImage(width: 256, height: 192)),
            ("checker", makeCheckerImage(size: 96, block: 3)),
            ("noise", makeNoiseImage(width: 97, height: 61, seed: 0xBD_6F_11)),
        ]
        var compared = 0
        for geometrySpec in geometries {
            let base = DiscGeometry(
                family: .bluRay,
                innerRadiusMm: geometrySpec.inner,
                outerRadiusMm: geometrySpec.outer,
                sectors: geometrySpec.sectors
            )
            let track = try BluRayTrackGeometry(
                innerRadiusMm: base.innerRadiusMm,
                outerRadiusMm: base.outerRadiusMm,
                totalSectors: base.sectors
            )
            let clusterCount = geometrySpec.sectors / BluRaySpec.sectorsPerCluster
            let clusters = [0, clusterCount / 2]
            for (name, image) in images {
                for invert in [false, true] {
                    let mapping = BluRayImagePayloadMapping(
                        image: image,
                        tone: .default,
                        geometry: track,
                        invert: invert
                    )
                    for cluster in clusters {
                        let sector = UInt32(cluster * BluRaySpec.sectorsPerCluster)
                        var fast = [UInt8](repeating: 0, count: BluRaySpec.payloadBytesPerCluster)
                        var exact = [UInt8](repeating: 0xFF, count: BluRaySpec.payloadBytesPerCluster)
                        try mapping.fillPayload(firstSector: sector, into: &fast)
                        try mapping.fillPayloadExact(firstSector: sector, into: &exact)
                        XCTAssertEqual(
                            fast, exact,
                            "\(name) 簇 \(cluster)（\(geometrySpec.sectors) 扇区，invert=\(invert)）的快速取样与精确取样不一致"
                        )
                        compared += 1
                    }
                }
            }
        }
        XCTAssertEqual(compared, 24)
    }

    func testFastSamplingMatchesExactReferenceAcrossTones() throws {
        let track = try BluRayTrackGeometry(innerRadiusMm: 24, outerRadiusMm: 40, totalSectors: 1024)
        let image = makeGradientImage(width: 300, height: 220)
        let tones: [ToneProfile] = [
            .legacyBinary,
            .default,
            ToneProfile(ditherStrength: 1, levels: 2, brightness: 12, srgbLinearization: 1),
        ]
        for tone in tones {
            let mapping = BluRayImagePayloadMapping(
                image: image, tone: tone, geometry: track, invert: false)
            var fast = [UInt8](repeating: 0, count: BluRaySpec.payloadBytesPerCluster)
            var exact = [UInt8](repeating: 0, count: BluRaySpec.payloadBytesPerCluster)
            try mapping.fillPayload(firstSector: 0, into: &fast)
            try mapping.fillPayloadExact(firstSector: 0, into: &exact)
            XCTAssertEqual(fast, exact, "影调 \(tone) 下快速取样与精确取样不一致")
        }
    }

    // MARK: - 并行生成 vs 串行生成

    func testPureDrawingOutputIsIdenticalSeriallyAndInParallel() throws {
        let serial = try withWorkers(1) {
            try generateISO(sectors: 128, dataDirectory: nil)
        }
        let parallel = try withWorkers(8) {
            try generateISO(sectors: 128, dataDirectory: nil)
        }
        XCTAssertEqual(serial, parallel, "纯绘图模式的串行与并行输出不一致")
        XCTAssertEqual(serial.count, 128 * 2048)
    }

    func testUDFImageOutputIsIdenticalSeriallyAndInParallel() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("parallel regression\n".utf8).write(to: directory.appendingPathComponent("readme.txt"))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 8192).write(to: directory.appendingPathComponent("sub/blob.bin"))

        let serial = try withWorkers(1) {
            try generateISO(sectors: 640, dataDirectory: directory)
        }
        let parallel = try withWorkers(8) {
            try generateISO(sectors: 640, dataDirectory: directory)
        }
        XCTAssertEqual(serial.count, 640 * 2048)
        XCTAssertEqual(parallel.count, serial.count)

        // UDF 的前缀/后缀里带生成时间戳（每次调用不同），不参与并行回归；
        // 绘图区完全由并行管线产生，必须逐字节一致。
        let plan = try UDFImageWriter.plan(
            sourceDirectory: directory,
            volumeSectors: 640,
            volumeLabel: "PERF",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let start = Int(plan.drawingStartLBA) * 2048
        let end = Int(plan.drawingEndLBAExclusive) * 2048
        XCTAssertLessThan(start, end)
        XCTAssertEqual(
            Array(serial[start..<end]),
            Array(parallel[start..<end]),
            "UDF 模式的绘图区在串行与并行下不一致"
        )
    }

    // MARK: - 辅助

    private func generateISO(sectors: Int, dataDirectory: URL?) throws -> [UInt8] {
        let request = GenerationRequest(
            geometry: DiscGeometry(
                family: .bluRay,
                innerRadiusMm: 24,
                outerRadiusMm: 40,
                sectors: sectors
            ),
            tone: .default,
            image: makeGradientImage(width: 160, height: 120),
            outputFormat: .iso,
            dataDirectory: dataDirectory,
            volumeLabel: "PERF",
            outputBaseURL: nil
        )
        let sink = DataSequentialSink(capacity: sectors * 2048)
        _ = try BluRayImageGenerator().generate(request, to: sink) { _ in }
        return sink.bytes
    }

    /// 临时设置 `DISCI_MAX_WORKERS`，结束后恢复原值（不影响其他测试）。
    private func withWorkers<T>(_ workers: Int, _ body: () throws -> T) rethrows -> T {
        let key = "DISCI_MAX_WORKERS"
        let previous = getenv(key).map { String(cString: $0) }
        setenv(key, String(workers), 1)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }
        return try body()
    }

    private func makeGradientImage(width: Int, height: Int) -> RasterImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let horizontal = Double(x) / Double(max(width - 1, 1))
                let vertical = Double(y) / Double(max(height - 1, 1))
                let value = UInt8(min(max(((horizontal + vertical) * 0.5 * 255).rounded(), 0), 255))
                let offset = (y * width + x) * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 255
            }
        }
        return RasterImage(width: width, height: height, pixels: pixels)
    }

    private func makeCheckerImage(size: Int, block: Int) -> RasterImage {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let value: UInt8 = ((x / block + y / block) % 2 == 0) ? 0 : 255
                let offset = (y * size + x) * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 255
            }
        }
        return RasterImage(width: size, height: size, pixels: pixels)
    }

    private func makeNoiseImage(width: Int, height: Int, seed: UInt64) -> RasterImage {
        var generator = SplitMix64(seed: seed)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let value = UInt8(truncatingIfNeeded: generator.next())
            pixels[offset] = value
            pixels[offset + 1] = UInt8(truncatingIfNeeded: generator.next())
            pixels[offset + 2] = UInt8(truncatingIfNeeded: generator.next())
            pixels[offset + 3] = 255
        }
        return RasterImage(width: width, height: height, pixels: pixels)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bluray-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
