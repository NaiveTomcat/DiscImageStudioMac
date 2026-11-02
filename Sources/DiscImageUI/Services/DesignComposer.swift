import CoreGraphics
import DiscImageCore
import Foundation

/// 设计画布合成：把图层栈按毫米坐标摊平成引擎需要的方形源图。
///
/// 坐标系约定（与源项目 `DesignComposer` 一致）：
/// - 方形画布中心 = 盘心，边长 = `2 × canvasOuterRadiusMm`；
/// - 图层位移单位毫米，+x 向右、+y **向下**；
/// - 旋转单位为度、顺时针为正；
/// - 图层导入时的基准尺寸：图片较长边铺满「内容环直径」（`2 × canvasOuterRadiusMm`），
///   `scale` 在其上再乘倍数。
public enum DesignComposer {
    /// 导出合成图尺寸（HANDOFF §6.D）。
    public static let exportSize = 8192
    /// 设计页预览合成图尺寸。
    public static let previewSize = 2048
    /// 最近工程缩略图尺寸。
    public static let thumbnailSize = 256
    /// 单张图层图片解码上限，超过的导入时一次性降采样。
    public static let maxDecodeDimension = 4096

    /// 图层图片在 scale=1 时的物理尺寸（mm）。
    public static func baseSizeMm(
        pixelWidth: Int,
        pixelHeight: Int,
        canvasOuterRadiusMm: Double
    ) -> CGSize {
        guard pixelWidth > 0, pixelHeight > 0, canvasOuterRadiusMm > 0 else { return .zero }
        let diameter = canvasOuterRadiusMm * 2
        if pixelWidth >= pixelHeight {
            return CGSize(width: diameter, height: diameter * Double(pixelHeight) / Double(pixelWidth))
        }
        return CGSize(width: diameter * Double(pixelWidth) / Double(pixelHeight), height: diameter)
    }

    /// 读入图层图片（带解码上限）。
    public static func loadLayerImage(at url: URL) throws -> RasterImage {
        let loaded = try RasterImage.load(contentsOf: url)
        return loaded.scaled(maxDimension: maxDecodeDimension)
    }

    /// 合成。`layerImages` 以图层 id 为键；缺失/不可读的图层会被跳过（界面上有占位提示）。
    public static func compose(
        layers: [DesignLayer],
        layerImages: [String: RasterImage],
        canvasOuterRadiusMm: Double,
        outputSize: Int
    ) throws -> RasterImage {
        guard outputSize > 0, outputSize <= 16_384 else {
            throw DiscError.invalidGeometry("合成图尺寸必须在 1…16384 像素之间（当前 \(outputSize)）。")
        }
        guard canvasOuterRadiusMm > 0, canvasOuterRadiusMm.isFinite else {
            throw DiscError.invalidGeometry("画布外半径必须为正数。")
        }

        let size = CGFloat(outputSize)
        let pixelsPerMm = size / CGFloat(canvasOuterRadiusMm * 2)
        let centre = size / 2
        var buffer = [UInt8](repeating: 0, count: outputSize * outputSize * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        let drawn: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: outputSize,
                height: outputSize,
                bitsPerComponent: 8,
                bytesPerRow: outputSize * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else { return false }
            context.interpolationQuality = .high
            // 背景透明 = 与黑底合成后为盘面最暗处。
            context.clear(CGRect(x: 0, y: 0, width: size, height: size))

            // 图层列表是「最上层在前」，所以从后往前画。
            for layer in layers.reversed() where layer.visible {
                guard let raster = layerImages[layer.id] else { continue }
                let base = baseSizeMm(
                    pixelWidth: raster.width,
                    pixelHeight: raster.height,
                    canvasOuterRadiusMm: canvasOuterRadiusMm
                )
                let width = base.width * layer.scale * pixelsPerMm
                let height = base.height * layer.scale * pixelsPerMm
                guard width.isFinite, height.isFinite, width > 0.5, height > 0.5 else { continue }
                guard let image = makeCGImage(from: raster) else { continue }

                context.saveGState()
                // 画布 +y 向下 → CG 用户空间 +y 向上；顺时针旋转 → 负角。
                context.translateBy(
                    x: centre + CGFloat(layer.translateXMm) * pixelsPerMm,
                    y: centre - CGFloat(layer.translateYMm) * pixelsPerMm
                )
                context.rotate(by: CGFloat(-layer.rotationDeg) * .pi / 180)
                context.translateBy(x: -width / 2, y: -height / 2)
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                context.restoreGState()
            }
            return true
        }
        guard drawn else {
            throw DiscError.io("无法创建合成位图上下文（\(outputSize)×\(outputSize)）")
        }
        return RasterImage(width: outputSize, height: outputSize, pixels: buffer)
    }

    /// 合成并写成 PNG。
    @discardableResult
    public static func writeCompositePNG(
        project: DiscProject,
        layerImages: [String: RasterImage],
        outputSize: Int,
        to url: URL
    ) throws -> RasterImage {
        let image = try compose(
            layers: project.layers,
            layerImages: layerImages,
            canvasOuterRadiusMm: project.canvasOuterRadiusMm,
            outputSize: outputSize
        )
        try image.writePNG(to: url)
        return image
    }

    /// 工程缩略图（256 px PNG → base64），写入 `.discproj` 供主页「最近工程」显示。
    public static func thumbnailBase64(
        project: DiscProject,
        layerImages: [String: RasterImage]
    ) throws -> String? {
        guard !project.layers.isEmpty else { return nil }
        let image = try compose(
            layers: project.layers,
            layerImages: layerImages,
            canvasOuterRadiusMm: project.canvasOuterRadiusMm,
            outputSize: thumbnailSize
        )
        return try image.pngData().base64EncodedString()
    }
}

/// RasterImage（预乘 RGBA8）→ CGImage。UI 层唯一需要 CoreGraphics 的桥。
public func makeCGImage(from raster: RasterImage) -> CGImage? {
    guard let provider = CGDataProvider(data: Data(raster.pixels) as CFData) else { return nil }
    let bitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    )
    return CGImage(
        width: raster.width,
        height: raster.height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: raster.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
    )
}
