import DiscImageCore
import Foundation

/// 把实拍照片按单应变换重采样成正视盘面图（矫正预览 + 描线底图）。
///
/// 像素坐标约定与 Core 一致：画布中心 = 盘心，画布半宽 = `canvasOuterRadiusMm`，
/// y 向下；照片像素同样 y 向下。变换来自 `CalibrationPhotoTransform`（照片 ↔ 盘面）。
public enum CalibrationRectifiedRenderer {
    /// 生成矫正预览。
    ///
    /// - Parameters:
    ///   - photo: 已缩放的实拍照片。
    ///   - transform: `CalibrationPhotoRectifier` 的结果。
    ///   - canvasOuterRadiusMm: 画布半宽（mm），通常 = 实体外缘 + 3 mm。
    ///   - pixelSize: 输出方形边长。
    public static func render(
        photo: RasterImage,
        transform: CalibrationPhotoTransform,
        canvasOuterRadiusMm: Double,
        pixelSize: Int = CalibrationModel.rectifiedPixelSize
    ) throws -> RasterImage {
        guard pixelSize > 0 else {
            throw DiscError.invalidGeometry("矫正画布尺寸必须为正。")
        }
        guard canvasOuterRadiusMm > 0, canvasOuterRadiusMm.isFinite else {
            throw DiscError.invalidGeometry("矫正画布半径必须为正。")
        }
        guard transform.isValidForDisc(canvasOuterRadiusMm) else {
            throw DiscError.invalidGeometry("照片变换在当前画布内退化，请重新矫正轮廓或缩小画布。")
        }

        let mmPerPixel = canvasOuterRadiusMm * 2 / Double(pixelSize)
        let centre = Double(pixelSize) / 2
        let photoWidth = photo.width
        let photoHeight = photo.height
        var pixels = [UInt8](repeating: 0, count: pixelSize * pixelSize * 4)

        for y in 0..<pixelSize {
            let discY = (Double(y) + 0.5 - centre) * mmPerPixel
            for x in 0..<pixelSize {
                let discX = (Double(x) + 0.5 - centre) * mmPerPixel
                let offset = (y * pixelSize + x) * 4
                let radius = (discX * discX + discY * discY).squareRoot()

                // 画布边缘（实体盘外）用深色背景，便于看清盘缘。
                if radius > canvasOuterRadiusMm {
                    write(12, 12, 14, to: &pixels, offset: offset)
                    continue
                }
                let source = transform.discToSource(CalibrationPoint(xMm: discX, yMm: discY))
                guard source.xMm.isFinite, source.yMm.isFinite,
                      source.xMm > -1, source.xMm < Double(photoWidth),
                      source.yMm > -1, source.yMm < Double(photoHeight) else {
                    write(18, 18, 20, to: &pixels, offset: offset)
                    continue
                }
                let sample = sampleRGB(photo, x: source.xMm, y: source.yMm)
                write(sample.0, sample.1, sample.2, to: &pixels, offset: offset)
            }
        }
        return RasterImage(width: pixelSize, height: pixelSize, pixels: pixels)
    }

    /// 双线性 RGB 采样（预乘 alpha 下与黑底合成后即盘面颜色）。
    private static func sampleRGB(
        _ image: RasterImage,
        x: Double,
        y: Double
    ) -> (UInt8, UInt8, UInt8) {
        let clampedX = min(max(x, 0), Double(image.width - 1))
        let clampedY = min(max(y, 0), Double(image.height - 1))
        let x0 = Int(clampedX)
        let y0 = Int(clampedY)
        let x1 = min(x0 + 1, image.width - 1)
        let y1 = min(y0 + 1, image.height - 1)
        let fx = clampedX - Double(x0)
        let fy = clampedY - Double(y0)

        func channel(_ channel: Int) -> UInt8 {
            let base = image.pixels
            func value(_ sx: Int, _ sy: Int) -> Double {
                Double(base[(sy * image.width + sx) * 4 + channel])
            }
            let top = value(x0, y0) + (value(x1, y0) - value(x0, y0)) * fx
            let bottom = value(x0, y1) + (value(x1, y1) - value(x0, y1)) * fx
            let result = top + (bottom - top) * fy
            return UInt8(min(max(result.rounded(), 0), 255))
        }
        return (channel(0), channel(1), channel(2))
    }

    private static func write(
        _ r: UInt8, _ g: UInt8, _ b: UInt8,
        to pixels: inout [UInt8],
        offset: Int
    ) {
        pixels[offset] = r
        pixels[offset + 1] = g
        pixels[offset + 2] = b
        pixels[offset + 3] = 255
    }
}
