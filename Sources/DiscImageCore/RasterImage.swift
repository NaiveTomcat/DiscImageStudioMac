import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// RGBA8 光栅图，**预乘 alpha**。
///
/// 预乘之后「与黑底合成」就是一个取分量本身的操作，盘面亮度直接由
/// `0.2126R + 0.7152G + 0.0722B` 得到，不需要再乘 alpha。
public struct RasterImage: Sendable {
    public let width: Int
    public let height: Int
    /// 行优先、每像素 4 字节（R, G, B, A），长度必须为 `width * height * 4`。
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0, "RasterImage 尺寸必须为正")
        precondition(pixels.count == width * height * 4, "RasterImage 像素数不匹配")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// 全黑图（测试与占位用）。
    public static func black(width: Int, height: Int) -> RasterImage {
        RasterImage(width: width, height: height, pixels: [UInt8](repeating: 0, count: width * height * 4))
    }

    /// 纯灰图（测试用）。
    public static func gray(width: Int, height: Int, value: UInt8) -> RasterImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = value
            pixels[offset + 1] = value
            pixels[offset + 2] = value
            pixels[offset + 3] = 255
        }
        return RasterImage(width: width, height: height, pixels: pixels)
    }

    /// 用 ImageIO 读入任意常见格式（PNG/JPEG/HEIC/TIFF…），统一转成预乘 RGBA8。
    public static func load(contentsOf url: URL) throws -> RasterImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw DiscError.io("无法读取图片：\(url.lastPathComponent)")
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw DiscError.io("图片格式无法解码：\(url.lastPathComponent)")
        }
        return try RasterImage(cgImage: image)
    }

    /// 从 Data 读入（剪贴板/拖拽）。
    public static func load(data: Data) throws -> RasterImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw DiscError.io("无法解码图片数据")
        }
        return try RasterImage(cgImage: image)
    }

    public init(cgImage: CGImage) throws {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else {
            throw DiscError.io("图片尺寸为 0")
        }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            throw DiscError.io("无法创建位图上下文（\(width)×\(height)）")
        }
        self.init(width: width, height: height, pixels: buffer)
    }

    /// 等比缩放到最长边不超过 `maxDimension`；已经够小就原样返回。
    public func scaled(maxDimension: Int) -> RasterImage {
        guard maxDimension > 0 else { return self }
        let longest = max(width, height)
        guard longest > maxDimension else { return self }
        let scale = Double(maxDimension) / Double(longest)
        let newWidth = max(1, Int((Double(width) * scale).rounded()))
        let newHeight = max(1, Int((Double(height) * scale).rounded()))
        return resized(width: newWidth, height: newHeight)
    }

    /// 双线性重采样。
    public func resized(width newWidth: Int, height newHeight: Int) -> RasterImage {
        guard newWidth > 0, newHeight > 0 else { return self }
        if newWidth == width && newHeight == height { return self }
        var output = [UInt8](repeating: 0, count: newWidth * newHeight * 4)
        let xScale = Double(width) / Double(newWidth)
        let yScale = Double(height) / Double(newHeight)
        for y in 0..<newHeight {
            let sourceY = min(max((Double(y) + 0.5) * yScale - 0.5, 0), Double(height - 1))
            let y0 = Int(sourceY)
            let y1 = min(y0 + 1, height - 1)
            let fy = sourceY - Double(y0)
            for x in 0..<newWidth {
                let sourceX = min(max((Double(x) + 0.5) * xScale - 0.5, 0), Double(width - 1))
                let x0 = Int(sourceX)
                let x1 = min(x0 + 1, width - 1)
                let fx = sourceX - Double(x0)
                let o = (y * newWidth + x) * 4
                for channel in 0..<4 {
                    let p00 = Double(pixels[(y0 * width + x0) * 4 + channel])
                    let p10 = Double(pixels[(y0 * width + x1) * 4 + channel])
                    let p01 = Double(pixels[(y1 * width + x0) * 4 + channel])
                    let p11 = Double(pixels[(y1 * width + x1) * 4 + channel])
                    let top = p00 + (p10 - p00) * fx
                    let bottom = p01 + (p11 - p01) * fx
                    output[o + channel] = UInt8(min(max((top + (bottom - top) * fy).rounded(), 0), 255))
                }
            }
        }
        return RasterImage(width: newWidth, height: newHeight, pixels: output)
    }

    /// 最近邻取亮度（0…255）。坐标越界时夹到边缘。
    public func luminance(x: Int, y: Int) -> Double {
        let clampedX = min(max(x, 0), width - 1)
        let clampedY = min(max(y, 0), height - 1)
        let offset = (clampedY * width + clampedX) * 4
        return 0.2126 * Double(pixels[offset])
            + 0.7152 * Double(pixels[offset + 1])
            + 0.0722 * Double(pixels[offset + 2])
    }

    /// 双线性取亮度（0…255）。坐标是连续像素坐标，0 表示第一列/行中心之外半个像素。
    public func luminance(bilinearX x: Double, bilinearY y: Double) -> Double {
        guard x.isFinite, y.isFinite else { return 0 }
        let clampedX = min(max(x, 0), Double(width - 1))
        let clampedY = min(max(y, 0), Double(height - 1))
        let x0 = Int(clampedX)
        let y0 = Int(clampedY)
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let fx = clampedX - Double(x0)
        let fy = clampedY - Double(y0)
        func sample(_ sx: Int, _ sy: Int) -> Double {
            let offset = (sy * width + sx) * 4
            return 0.2126 * Double(pixels[offset])
                + 0.7152 * Double(pixels[offset + 1])
                + 0.0722 * Double(pixels[offset + 2])
        }
        let top = sample(x0, y0) + (sample(x1, y0) - sample(x0, y0)) * fx
        let bottom = sample(x0, y1) + (sample(x1, y1) - sample(x0, y1)) * fx
        return top + (bottom - top) * fy
    }

    /// 整张图是否已是「不透明 + 纯黑白」——这种情况采样时不要插值，
    /// 否则会把已经抖动好的密度抹成中间灰。
    public var isOpaqueBinaryGrayscale: Bool {
        var offset = 0
        while offset < pixels.count {
            let value = pixels[offset]
            if pixels[offset + 1] != value || pixels[offset + 2] != value
                || pixels[offset + 3] != 255 || (value != 0 && value != 255) {
                return false
            }
            offset += 4
        }
        return true
    }

    /// 导出 PNG（设计页合成图、UI 快照、测试用）。
    public func pngData() throws -> Data {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            throw DiscError.io("无法创建像素数据源")
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw DiscError.io("无法构造 CGImage")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw DiscError.io("无法创建 PNG 编码器")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw DiscError.io("PNG 编码失败")
        }
        return data as Data
    }

    /// 写入 PNG 文件。
    public func writePNG(to url: URL) throws {
        try pngData().write(to: url, options: .atomic)
    }
}
