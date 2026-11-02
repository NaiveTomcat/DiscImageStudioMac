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

    /// 合成一张「盘片照片」：实体外缘/中心孔/盘体/背景有明显灰度差，供标定测试用。
    ///
    /// 只有形状与灰度，不模拟透视——矫正算法只吃控制点，图片只负责让界面有东西可看。
    static func syntheticDiscPhoto(size: Int = 512) -> RasterImage {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let centre = Double(size) / 2
        let outerRadius = Double(size) * 0.43
        let holeRadius = outerRadius * 0.125
        for y in 0..<size {
            for x in 0..<size {
                let dx = Double(x) + 0.5 - centre
                let dy = Double(y) + 0.5 - centre
                let radius = (dx * dx + dy * dy).squareRoot()
                let value: UInt8
                if radius > outerRadius * 1.02 {
                    value = 20                                   // 桌面背景
                } else if radius > outerRadius * 0.985 {
                    value = 235                                  // 实体外缘亮边
                } else if radius < holeRadius * 0.94 {
                    value = 12                                   // 中心孔（透黑）
                } else if radius < holeRadius * 1.04 {
                    value = 210                                  // 中心孔亮边
                } else {
                    // 盘体：随半径轻微变化的灰阶 + 几条同心亮环，方便看清矫正效果。
                    let tone = 105 + 30 * (radius / outerRadius)
                    let ring = Int(radius / (outerRadius / 18)).isMultiple(of: 3) ? 18 : 0
                    value = UInt8(min(255, Int(tone) + ring))
                }
                let offset = (y * size + x) * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 255
            }
        }
        return RasterImage(width: size, height: size, pixels: pixels)
    }

    /// 小几何（DVD 24–40 mm / 1024 扇区），让标定图案与反推测试跑得快。
    static func calibrationGeometry(family: DiscFamily = .dvd) -> DiscGeometry {
        switch family {
        case .dvd:
            return DiscGeometry(
                family: .dvd,
                innerRadiusMm: 24,
                outerRadiusMm: 40,
                sectors: 1024,
                channelBitLengthNm: 133.3
            )
        case .cd:
            return DiscGeometry(
                family: .cd,
                innerRadiusMm: 24.5,
                outerRadiusMm: 56.8,
                sectors: 1000,
                linearVelocityMmPerSecond: 1200
            )
        case .bluRay:
            return DiscGeometry(
                family: .bluRay,
                innerRadiusMm: 24,
                outerRadiusMm: 40,
                sectors: 1024
            )
        }
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
