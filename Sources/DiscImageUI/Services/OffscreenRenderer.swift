import DiscImageCore
import SwiftUI

/// SwiftUI 视图离屏渲染（UI 回归手段，没有像素基线）。
///
/// 用 `ImageRenderer` 把任意 SwiftUI 视图渲染成 PNG/`RasterImage`：
/// 测试断言 PNG 非空、尺寸正确；应用里也可以用它生成工程缩略图。
@MainActor
public enum OffscreenRenderer {
    /// 渲染成 PNG 数据。
    public static func png<Content: View>(
        _ view: Content,
        size: CGSize,
        scale: CGFloat = 1,
        colorScheme: ColorScheme = .dark
    ) throws -> Data {
        let image = try raster(view, size: size, scale: scale, colorScheme: colorScheme)
        return try image.pngData()
    }

    /// 渲染成 `RasterImage`（预乘 RGBA8）。
    public static func raster<Content: View>(
        _ view: Content,
        size: CGSize,
        scale: CGFloat = 1,
        colorScheme: ColorScheme = .dark
    ) throws -> RasterImage {
        guard size.width > 0, size.height > 0 else {
            throw DiscError.io("离屏渲染尺寸必须为正（当前 \(size)）")
        }
        let content = view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = max(scale, 0.1)
        renderer.proposedSize = ProposedViewSize(size)
        guard let cgImage = renderer.cgImage else {
            throw DiscError.io("ImageRenderer 未能生成位图（\(Int(size.width))×\(Int(size.height))）")
        }
        return try RasterImage(cgImage: cgImage)
    }

    /// 渲染并写入 PNG 文件（测试产物落到工作区临时目录后清理）。
    @discardableResult
    public static func writePNG<Content: View>(
        _ view: Content,
        size: CGSize,
        scale: CGFloat = 1,
        colorScheme: ColorScheme = .dark,
        to url: URL
    ) throws -> URL {
        let data = try png(view, size: size, scale: scale, colorScheme: colorScheme)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// 把 base64 PNG（工程缩略图）解码成 SwiftUI 可直接显示的 `CGImage`。
public func decodeBase64PNGImage(_ base64: String) -> CGImage? {
    guard let data = Data(base64Encoded: base64) else { return nil }
    guard let raster = try? RasterImage.load(data: data) else { return nil }
    return makeCGImage(from: raster)
}
