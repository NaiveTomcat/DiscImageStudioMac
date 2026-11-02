import DiscImageCore
import Foundation

/// 预览上「文件区」的扇区区间。引擎尚未接入时由数据字节数粗估；
/// 引擎落地后应改为使用引擎实际报告的文件区范围。
public struct FileRegion: Equatable, Sendable {
    /// 起始扇区（含）。
    public var startSector: Double
    /// 结束扇区（不含）。
    public var endSector: Double

    public init(startSector: Double, endSector: Double) {
        self.startSector = startSector
        self.endSector = endSector
    }

    public var isEmpty: Bool { endSector <= startSector }

    /// 由数据盘目录总字节粗估文件区：每扇区 2048 字节 + 文件系统元数据余量。
    /// `atOuterRing` 决定文件区贴外圈还是内圈（源项目「文件区放置」约定）。
    public static func estimated(
        dataByteCount: Int64,
        geometry: DiscGeometry,
        atOuterRing: Bool
    ) -> FileRegion? {
        guard geometry.sectors > 0, dataByteCount > 0 else { return nil }
        // ISO9660/UDF 的路径表、目录记录、BD 的 32 扇区对齐都吃扇区，留 2% + 512 扇区余量。
        let rawSectors = Double(dataByteCount) / 2048.0
        let overhead = 512.0 + rawSectors * 0.02
        let needed = min(rawSectors + overhead, Double(geometry.sectors))
        guard needed > 0 else { return nil }
        let fraction = needed / Double(geometry.sectors)
        if atOuterRing {
            return FileRegion(startSector: (1 - fraction) * Double(geometry.sectors), endSector: Double(geometry.sectors))
        }
        return FileRegion(startSector: 0, endSector: fraction * Double(geometry.sectors))
    }
}

/// 预览渲染模式。
public enum DiscPreviewMode: String, CaseIterable, Sendable, Identifiable {
    /// 设计投影：按影调把设计图二值化后投到盘面（能看到刻出来的图案）。
    case design
    /// 成品读回：直接显示灰度，不做二值判定。需要引擎产物支持，当前仅占位。
    case readback

    public var id: String { rawValue }

    public var displayNameZH: String {
        switch self {
        case .design: return "设计投影"
        case .readback: return "成品读回"
        }
    }
}

/// 盘面预览：用 `DiscProjection` 把设计投影成极坐标盘面图。
///
/// 渲染约定（照搬源项目 `FileRegionPreviewOverlay` 的颜色）：
/// - 画布中心 = 盘心，画布半宽 = 工程画布外半径；
/// - 数据区之外透明，中心孔深灰；
/// - 图案黑白由 `ToneProfile.useWhite` 决定（预览是近似采样，不是逐字节编码）；
/// - **文件区黄色 #FACC15**，只出现在预览上，绝不进入刻录流。
public enum DiscPreviewRenderer {
    /// 预览里代表「白」（亮）与「黑」（暗）的颜色。
    public static let whiteRGB: (UInt8, UInt8, UInt8) = (232, 232, 232)
    public static let blackRGB: (UInt8, UInt8, UInt8) = (16, 16, 16)
    public static let fileRegionRGB: (UInt8, UInt8, UInt8) = (250, 204, 21)
    public static let hubRGB: (UInt8, UInt8, UInt8) = (28, 28, 28)
    public static let hubRimRGB: (UInt8, UInt8, UInt8) = (96, 96, 96)

    /// 渲染到内存中的 RasterImage。
    /// - Parameters:
    ///   - project: 工程（提供几何、影调、画布半径）。
    ///   - sourceImage: 已合成的方形设计图（`DesignComposer.compose` 的产物）；nil 表示空白设计。
    ///   - fileRegion: 文件区（黄色标记），nil 表示纯绘图。
    ///   - outputSize: 预览边长（像素）。
    ///   - mode: 设计投影 / 成品读回。
    public static func render(
        project: DiscProject,
        sourceImage: RasterImage?,
        fileRegion: FileRegion?,
        outputSize: Int = 1024,
        mode: DiscPreviewMode = .design
    ) throws -> RasterImage {
        guard outputSize > 0, outputSize <= 8192 else {
            throw DiscError.invalidGeometry("预览尺寸必须在 1…8192 像素之间。")
        }
        let geometry = project.geometry
        let canvasOuterRadiusMm = project.canvasOuterRadiusMm
        let projection = DiscProjection(canvasSize: outputSize, imageOuterRadiusMm: canvasOuterRadiusMm)
        let tone = project.effectiveTone
        let inner = geometry.innerRadiusMm
        let outer = min(geometry.outerRadiusMm, canvasOuterRadiusMm)
        let mmPerPixel = projection.mmPerPixel
        let centre = Double(outputSize) / 2

        let outerSquared = outer * outer
        let rimWidthMm = max(mmPerPixel * 1.5, 0.02)

        let spiral = geometry.spiral
        let fileInnerSquared: Double
        let fileOuterSquared: Double
        if let fileRegion, !fileRegion.isEmpty {
            let startRadius = spiral.radiusAt(sectorCoordinate: min(fileRegion.startSector, fileRegion.endSector))
            let endRadius = spiral.radiusAt(sectorCoordinate: max(fileRegion.startSector, fileRegion.endSector))
            fileInnerSquared = startRadius * startRadius
            fileOuterSquared = endRadius * endRadius
        } else {
            fileInnerSquared = .infinity
            fileOuterSquared = .infinity
        }

        var pixels = [UInt8](repeating: 0, count: outputSize * outputSize * 4)
        let sourcePixelWidth = sourceImage?.width ?? 0
        let sourceScale = Double(sourcePixelWidth) / Double(outputSize)

        for y in 0..<outputSize {
            let dy = (Double(y) + 0.5) - centre
            for x in 0..<outputSize {
                let dx = (Double(x) + 0.5) - centre
                let radiusSquared = dx * dx + dy * dy
                let offset = (y * outputSize + x) * 4

                // 所有半径比较都用毫米；像素半径只在最后换算一次。
                let radiusMm = radiusSquared.squareRoot() * mmPerPixel
                let radiusSquaredMm = radiusMm * radiusMm

                if radiusSquaredMm > outerSquared {
                    // 数据区之外：透明（盘面外缘）。
                    continue
                }
                if radiusMm < inner {
                    // 中心孔：深灰 + 内缘亮边，让预览一眼看出盘心位置。
                    let rim = radiusMm >= inner - rimWidthMm
                    let colour = rim ? hubRimRGB : hubRGB
                    write(colour, to: &pixels, offset: offset)
                    continue
                }
                if radiusMm < inner + rimWidthMm {
                    write(hubRimRGB, to: &pixels, offset: offset)
                    continue
                }

                // 文件区：黄色标记优先于图案。
                if radiusSquaredMm >= fileInnerSquared && radiusSquaredMm < fileOuterSquared {
                    write(fileRegionRGB, to: &pixels, offset: offset)
                    continue
                }

                // 采样设计图：与预览同处一个毫米坐标系，按画布比例换算。
                guard let sourceImage, sourcePixelWidth > 0 else {
                    write(blackRGB, to: &pixels, offset: offset)
                    continue
                }
                let sourceX = (Double(x) + 0.5) * sourceScale
                let sourceY = (Double(y) + 0.5) * sourceScale
                let luminance = sourceImage.luminance(bilinearX: sourceX, bilinearY: sourceY)

                let isWhite: Bool
                switch mode {
                case .design:
                    // 预览用像素序号近似引擎的逐字节抖动相位；真实编码相位由引擎决定。
                    let sampleIndex = Int64(y) &* Int64(outputSize) &+ Int64(x)
                    isWhite = tone.useWhite(
                        UInt8(min(max(luminance.rounded(), 0), 255)),
                        sampleIndex: sampleIndex
                    )
                case .readback:
                    isWhite = luminance >= 128
                }
                write(isWhite ? whiteRGB : blackRGB, to: &pixels, offset: offset)
            }
        }
        return RasterImage(width: outputSize, height: outputSize, pixels: pixels)
    }

    /// 渲染并编码成 PNG。
    public static func pngData(
        project: DiscProject,
        sourceImage: RasterImage?,
        fileRegion: FileRegion?,
        outputSize: Int = 1024,
        mode: DiscPreviewMode = .design
    ) throws -> Data {
        let image = try render(
            project: project,
            sourceImage: sourceImage,
            fileRegion: fileRegion,
            outputSize: outputSize,
            mode: mode
        )
        return try image.pngData()
    }

    /// 预览 2048 px（HANDOFF §6.D 的预览尺寸）。
    public static func previewImage(
        project: DiscProject,
        sourceImage: RasterImage?,
        fileRegion: FileRegion?,
        mode: DiscPreviewMode = .design
    ) throws -> RasterImage {
        try render(
            project: project,
            sourceImage: sourceImage,
            fileRegion: fileRegion,
            outputSize: DesignComposer.previewSize,
            mode: mode
        )
    }

    private static func write(
        _ colour: (UInt8, UInt8, UInt8),
        to pixels: inout [UInt8],
        offset: Int
    ) {
        pixels[offset] = colour.0
        pixels[offset + 1] = colour.1
        pixels[offset + 2] = colour.2
        pixels[offset + 3] = 255
    }
}
