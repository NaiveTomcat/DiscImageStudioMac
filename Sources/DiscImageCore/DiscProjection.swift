import Foundation

/// 方形画布 ↔ 盘面极坐标的投影。
///
/// 约定来自源项目的采样公式：
/// `pixelRadius = (size / 2) · r / imageOuterRadiusMm`，即**画布中心 = 盘心**，
/// 画布半宽对应 `imageOuterRadiusMm`。CD 默认 57.5 mm（图可以略超出盘面外缘），
/// DVD/BD 直接用盘片外半径，保证图案不越界。
public struct DiscProjection: Sendable, Equatable {
    public let canvasSize: Int
    public let imageOuterRadiusMm: Double

    public init(canvasSize: Int, imageOuterRadiusMm: Double) {
        precondition(canvasSize > 0, "画布尺寸必须为正")
        self.canvasSize = canvasSize
        self.imageOuterRadiusMm = imageOuterRadiusMm
    }

    /// 每像素对应多少毫米。
    public var mmPerPixel: Double {
        imageOuterRadiusMm * 2.0 / Double(canvasSize)
    }

    /// 半宽对应的毫米数。
    public var halfExtentMm: Double { imageOuterRadiusMm }

    /// 画布中心坐标（浮点，按像素中心计）。
    public var centre: (x: Double, y: Double) {
        let half = Double(canvasSize) / 2.0
        return (half, half)
    }

    /// 画布坐标 → 盘面极坐标。角度以 +x 轴起、逆时针为正。
    public func polar(canvasX x: Double, canvasY y: Double) -> (radiusMm: Double, angleRadians: Double) {
        let centre = self.centre
        let dx = x - centre.x
        let dy = y - centre.y
        return ((dx * dx + dy * dy).squareRoot() * mmPerPixel, atan2(dy, dx))
    }

    /// 盘面极坐标 → 画布坐标（`polar` 的逆）。
    public func canvasPoint(radiusMm radius: Double, angleRadians angle: Double) -> (x: Double, y: Double) {
        let centre = self.centre
        let pixelRadius = radius / mmPerPixel
        return (centre.x + pixelRadius * cos(angle), centre.y + pixelRadius * sin(angle))
    }

    /// 画布坐标是否落在盘面数据区内。
    public func isInsideDataArea(canvasX x: Double, canvasY y: Double, innerRadiusMm: Double, outerRadiusMm: Double) -> Bool {
        let radius = polar(canvasX: x, canvasY: y).radiusMm
        return radius >= innerRadiusMm && radius <= outerRadiusMm
    }

    /// 画布坐标系 → 图片像素坐标（最近邻、可越界，由调用方夹紧）。
    public func imagePixel(canvasX x: Double, canvasY y: Double, imageSize: Int) -> (x: Double, y: Double) {
        // 画布与图片同尺寸时是恒等映射；不同尺寸时按中心对齐缩放。
        let scale = Double(imageSize) / Double(canvasSize)
        return (x * scale, y * scale)
    }
}
