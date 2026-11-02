import DiscImageCore
import DiscImageUI
import Foundation
import XCTest

/// 工作包 D 测试共用工具。
///
/// 测试产物一律落在工作区内的 `.build-ui/ui-test-tmp/`（DSH 沙箱禁止写
/// `~/Library`，也不要污染文档目录），测试结束自行清理。
enum UITestSupport {
    /// 从本文件路径反推包根目录：Tests/DiscImageUITests/TestSupport.swift → 上三级。
    static var workspaceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var scratchRoot: URL {
        workspaceRoot.appendingPathComponent(".build-ui/ui-test-tmp", isDirectory: true)
    }

    static func makeTempDirectory(_ label: String) throws -> URL {
        let safe = label.replacingOccurrences(of: " ", with: "-")
        let url = scratchRoot
            .appendingPathComponent("\(safe)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func removeQuietly(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func writePNG(
        _ raster: RasterImage,
        named name: String,
        in directory: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try raster.writePNG(to: url)
        return url
    }

    static func gray(width: Int, height: Int, value: UInt8) -> RasterImage {
        RasterImage.gray(width: width, height: height, value: value)
    }

    /// 半白半黑的竖条图（左白右黑），用来验证合成方向/位移。
    static func verticalHalves(width: Int, height: Int) -> RasterImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8 = x < width / 2 ? 255 : 0
                let offset = (y * width + x) * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 255
            }
        }
        return RasterImage(width: width, height: height, pixels: pixels)
    }

    /// 半白半黑的横条图（上半白、下半黑），用来验证没有上下翻转。
    static func horizontalHalves(width: Int, height: Int) -> RasterImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8 = y < height / 2 ? 255 : 0
                let offset = (y * width + x) * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 255
            }
        }
        return RasterImage(width: width, height: height, pixels: pixels)
    }

    static func sampleProject(family: DiscFamily = .cd) -> DiscProject {
        DiscProject.makeNew(
            name: "测试工程",
            preset: DiscPreset.defaultPreset(for: family)
        )
    }

    @MainActor
    static func waitUntil(
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("等待条件超时（\(timeout)s）", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// 测试替身：不编码任何真实介质，只按约定写字节、报进度，用来验证 UI 调度层。
struct StubGenerator: DiscImageGenerator {
    var family: DiscFamily
    var byteCount: Int = 4096
    /// 写多少字节后检查取消（模拟引擎的阶段边界）。
    var checksCancellation = true
    var failure: DiscError?

    func generate(
        _ request: GenerationRequest,
        to sink: SequentialSink,
        progress: @Sendable (DiscProgress) -> Void
    ) throws -> GenerationResult {
        progress(DiscProgress(stage: "mapping", message: "开始（测试）", fraction: 0))
        if let failure { throw failure }
        var remaining = byteCount
        var written = 0
        while remaining > 0 {
            if checksCancellation { try request.cancellation.check() }
            let chunk = [UInt8](repeating: 0x5A, count: min(512, remaining))
            try sink.write(chunk)
            remaining -= chunk.count
            written += chunk.count
            progress(DiscProgress(
                stage: "mapping",
                message: "已写 \(written) 字节（测试）",
                fraction: Double(written) / Double(byteCount)
            ))
        }
        return GenerationResult(byteCount: Int64(written), summary: "测试引擎：\(family.displayNameZH)")
    }
}
