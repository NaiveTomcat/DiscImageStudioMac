import DiscImageCore
import Foundation
import ImageIO

/// 标定照片导入：按 EXIF 方向摆正 + 缩到交互尺寸。
///
/// `RasterImage.load(contentsOf:)` 只解码原始像素、不处理 EXIF `Orientation`；
/// 手机竖拍照片直接进界面会躺着，控制点很难拖。这里用 ImageIO 的缩略图选项
/// （`kCGImageSourceCreateThumbnailWithTransform`）同时完成方向修正与降采样。
enum CalibrationPhotoLoader {
    static func load(
        contentsOf url: URL,
        maxDimension: Int = CalibrationPhotoSession.maximumImageDimension
    ) throws -> RasterImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw DiscError.io("无法读取照片：\(url.lastPathComponent)")
        }
        guard CGImageSourceGetCount(source) > 0 else {
            throw DiscError.io("照片没有可读取的图像：\(url.lastPathComponent)")
        }
        let dimension = min(max(maxDimension, 64), 4096)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: dimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw DiscError.io("照片解码失败：\(url.lastPathComponent)")
        }
        return try RasterImage(cgImage: image)
    }
}
