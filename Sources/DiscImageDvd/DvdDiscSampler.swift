import DiscImageCore
import Foundation

/// 方形图片 ↔ 盘面毫米坐标的采样器。
///
/// 与源项目 `RasterImage.SampleDisc` 同一套约定（HANDOFF §2.1）：
/// 图心对盘心，`pixelRadius = (size/2) · r / outerRadiusMm`，y 轴向下翻转；
/// 越界当透明；二值不透明图用最近邻（不要再插值，否则抖动好的中调会被抹平），
/// 其余用按 alpha 加权的双线性。
struct DvdDiscSampler: Sendable {
    let image: RasterImage
    let outerRadiusMm: Double
    /// 每毫米对应的像素数。
    private let pixelsPerMillimetre: Double
    private let useNearestNeighbour: Bool
    private let centreX: Double
    private let centreY: Double
    /// 整张图是否全不透明。是的话双线性可以省掉 alpha 归一化。
    private let isOpaque: Bool

    init(image: RasterImage, outerRadiusMm: Double) {
        self.image = image
        self.outerRadiusMm = outerRadiusMm
        let shorterSide = Double(min(image.width, image.height))
        pixelsPerMillimetre = (shorterSide - 1) / (2 * outerRadiusMm)
        centreX = Double(image.width - 1) / 2
        centreY = Double(image.height - 1) / 2
        useNearestNeighbour = image.isOpaqueBinaryGrayscale
        var opaque = true
        var offset = 3
        while offset < image.pixels.count {
            if image.pixels[offset] != 255 {
                opaque = false
                break
            }
            offset += 4
        }
        isOpaque = opaque
    }

    /// 盘面坐标（mm，x 向右、y 向上）→（亮度 0…255，alpha 0…255）。
    /// 落在图外时返回 `(0, 0)`。
    func sample(xMm: Double, yMm: Double) -> (luminance: UInt8, alpha: UInt8) {
        let pixelX = centreX + xMm * pixelsPerMillimetre
        let pixelY = centreY - yMm * pixelsPerMillimetre
        let maxX = Double(image.width - 1)
        let maxY = Double(image.height - 1)
        guard pixelX.isFinite, pixelY.isFinite,
              pixelX >= 0, pixelY >= 0, pixelX <= maxX, pixelY <= maxY else {
            return (0, 0)
        }

        if useNearestNeighbour {
            let x = min(max(Int((pixelX + 0.5).rounded(.down)), 0), image.width - 1)
            let y = min(max(Int((pixelY + 0.5).rounded(.down)), 0), image.height - 1)
            let offset = (y * image.width + x) * 4
            return (image.pixels[offset], 255)
        }

        let x0 = Int(pixelX.rounded(.down))
        let y0 = Int(pixelY.rounded(.down))
        let x1 = min(x0 + 1, image.width - 1)
        let y1 = min(y0 + 1, image.height - 1)
        let horizontal = pixelX - Double(x0)
        let vertical = pixelY - Double(y0)

        if isOpaque {
            let red = DvdDiscSampler.bilinearChannel(0, x0, y0, x1, y1, horizontal, vertical, image)
            let green = DvdDiscSampler.bilinearChannel(1, x0, y0, x1, y1, horizontal, vertical, image)
            let blue = DvdDiscSampler.bilinearChannel(2, x0, y0, x1, y1, horizontal, vertical, image)
            let luminance = (0.2126 * red + 0.7152 * green + 0.0722 * blue)
                .rounded(.toNearestOrAwayFromZero)
            return (UInt8(min(max(luminance, 0), 255)), 255)
        }

        var totalAlpha = 0.0
        var weightedRed = 0.0
        var weightedGreen = 0.0
        var weightedBlue = 0.0

        func accumulate(_ x: Int, _ y: Int, _ weight: Double) {
            let offset = (y * image.width + x) * 4
            let alpha = Double(image.pixels[offset + 3]) / 255.0
            let weightedAlpha = weight * alpha
            totalAlpha += weightedAlpha
            guard alpha > 0 else { return }
            // 像素是预乘 alpha 的，先还原成直通颜色再按源项目的口径加权。
            let unpremultiply = 1.0 / alpha
            weightedRed += weightedAlpha * Double(image.pixels[offset]) * unpremultiply
            weightedGreen += weightedAlpha * Double(image.pixels[offset + 1]) * unpremultiply
            weightedBlue += weightedAlpha * Double(image.pixels[offset + 2]) * unpremultiply
        }

        accumulate(x0, y0, (1 - horizontal) * (1 - vertical))
        accumulate(x1, y0, horizontal * (1 - vertical))
        accumulate(x0, y1, (1 - horizontal) * vertical)
        accumulate(x1, y1, horizontal * vertical)

        guard totalAlpha > 0 else { return (0, 0) }
        let inverseAlpha = 1.0 / totalAlpha
        let red = weightedRed * inverseAlpha
        let green = weightedGreen * inverseAlpha
        let blue = weightedBlue * inverseAlpha
        let luminance = (0.2126 * red + 0.7152 * green + 0.0722 * blue)
            .rounded(.toNearestOrAwayFromZero)
        let alpha = (totalAlpha * 255).rounded(.toNearestOrAwayFromZero)
        return (UInt8(min(max(luminance, 0), 255)), UInt8(min(max(alpha, 0), 255)))
    }

    private static func bilinearChannel(
        _ channel: Int,
        _ x0: Int,
        _ y0: Int,
        _ x1: Int,
        _ y1: Int,
        _ horizontal: Double,
        _ vertical: Double,
        _ image: RasterImage
    ) -> Double {
        let rowStride = image.width * 4
        let p00 = Double(image.pixels[y0 * rowStride + x0 * 4 + channel])
        let p10 = Double(image.pixels[y0 * rowStride + x1 * 4 + channel])
        let p01 = Double(image.pixels[y1 * rowStride + x0 * 4 + channel])
        let p11 = Double(image.pixels[y1 * rowStride + x1 * 4 + channel])
        let top = p00 + (p10 - p00) * horizontal
        let bottom = p01 + (p11 - p01) * horizontal
        return top + (bottom - top) * vertical
    }
}
