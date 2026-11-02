import Foundation

/// 内置标定图案 `target_slim.png`（2400 × 2400，九条细同心圆 + 十字线）。
///
/// 坐标约定与普通图片编码器一致（见上游 `CalibrationReferencePattern`）：
/// - 画布中心 = 盘心；
/// - 「生成外半径」对应画布半宽；
/// - DVD 的像素中心基准是 `(2400 − 1) / 2 = 1199.5`，CD / BD 是 `1200`；
/// - y 向下。
///
/// 图案**先按生成外半径缩放整张原图，再裁掉内半径以内（以及 BD 绘图范围以外）的环带**。
/// 预览用的 120 mm 盘面背景不是原图的固定物理尺寸，不参与这张图的编码尺度。
public enum CalibrationPattern {
    /// 原图像素尺寸。
    public static let pixelSize = 2400
    /// 九条同心圆在原图上的参考半径（像素），仅供观察，不参与反推。
    public static let ringRadiiPixels: [Double] = [490, 570, 650, 730, 810, 890, 970, 1050, 1130]
    /// 线宽约 10 像素。
    public static let nominalLineWidthPixels = 10
    /// 预览背景半径（mm），只用于界面画 12 cm 盘面，不是编码尺度。
    public static let canvasRadiusMm = 60

    /// 固定参考文件指纹（与资源 README 一致；测试里用来确认资源没被改动）。
    public static let pngSha256 = "c98ffe87db7cf9c3f132352814e1ce611c44f704de5b7212da4083188257c829"
    public static let graySha256 = "3d351bdfb817b943c1d1b4aedc97fc4f0a111e7e1537748f70cb5b180ba96852"

    // MARK: - 坐标映射

    /// 像素中心基准（DVD 用 1199.5，其余用 1200，与上游一致）。
    public static func pixelCentre(family: DiscFamily) -> Double {
        family == .dvd ? Double(pixelSize - 1) / 2 : Double(pixelSize) / 2
    }

    /// 原图 1 像素对应的毫米数（按生成外半径缩放）。
    public static func millimetresPerPixel(outerRadiusMm: Double, family: DiscFamily) -> Double {
        outerRadiusMm / pixelCentre(family: family)
    }

    /// 盘面毫米坐标 → 原图像素坐标（`sample` 内部用的正向映射）。
    public static func discToPixel(
        xMm: Double,
        yMm: Double,
        outerRadiusMm: Double,
        family: DiscFamily
    ) -> (x: Double, y: Double) {
        let centre = pixelCentre(family: family)
        let scale = centre / outerRadiusMm
        return (centre + xMm * scale, centre + yMm * scale)
    }

    /// 原图像素坐标 → 盘面毫米坐标（普通编码器映射的逆）。
    public static func pixelToDisc(
        x: Double,
        y: Double,
        outerRadiusMm: Double,
        family: DiscFamily
    ) -> CalibrationPoint {
        let centre = pixelCentre(family: family)
        let scale = millimetresPerPixel(outerRadiusMm: outerRadiusMm, family: family)
        return CalibrationPoint(xMm: (x - centre) * scale, yMm: (y - centre) * scale)
    }

    // MARK: - 原图与像素采样

    /// 原图（未缩放、未裁切的 2400 × 2400 参考图）。
    public static func referenceImage() throws -> RasterImage {
        try loadReferenceImage()
    }

    /// 与 `referenceImage()` 等价；保留给只关心「内置图案」的调用方。
    public static func image() throws -> RasterImage {
        try loadReferenceImage()
    }

    /// 未二值化的 8 位灰度像素（行优先，2400 × 2400）。
    public static func grayPixels() throws -> [UInt8] {
        try loadGrayPixels()
    }

    /// 按生成外半径缩放 + 裁切后的图案（2400 × 2400）。
    public static func image(geometry: DiscGeometry) throws -> RasterImage {
        try image(
            geometry: geometry,
            drawingStartSector: 0,
            drawingEndSectorExclusive: 0,
            canvasSize: pixelSize
        )
    }

    public static func image(
        generation: CalibrationGenerationSnapshot,
        canvasSize: Int = pixelSize
    ) throws -> RasterImage {
        try image(
            geometry: generation.geometry,
            drawingStartSector: generation.drawingStartSector,
            drawingEndSectorExclusive: generation.drawingEndSectorExclusive,
            canvasSize: canvasSize
        )
    }

    /// 导出裁切后的图案 PNG。按原图 2400 × 2400 输出，不加入预览背景边距。
    public static func writePNG(to url: URL, geometry: DiscGeometry) throws {
        try image(geometry: geometry).writePNG(to: url)
    }

    public static func writePNG(to url: URL, generation: CalibrationGenerationSnapshot) throws {
        try image(generation: generation).writePNG(to: url)
    }

    /// 按外半径 / 环带裁切生成图案。`canvasSize` 供测试与小尺寸预览使用。
    public static func image(
        geometry: DiscGeometry,
        drawingStartSector: Int,
        drawingEndSectorExclusive: Int,
        canvasSize: Int = pixelSize
    ) throws -> RasterImage {
        guard canvasSize > 0 else {
            throw DiscError.invalidGeometry("画布尺寸必须为正数。")
        }
        let parameters = CalibrationParameters(
            geometry: geometry,
            drawingStartSector: drawingStartSector,
            drawingEndSectorExclusive: drawingEndSectorExclusive
        )
        try parameters.validate()
        let gray = try loadGrayPixels()

        let inner = parameters.drawingInnerRadiusMm
        let outer = parameters.drawingOuterRadiusMm
        // 画布中心沿用该介质的像素约定（DVD 1199.5、CD/BD 1200），再按画布尺寸等比缩放。
        let centre = pixelCentre(family: geometry.family) * Double(canvasSize) / Double(pixelSize)
        let scale = centre / geometry.outerRadiusMm
        var pixels = [UInt8](repeating: 255, count: canvasSize * canvasSize * 4)
        let innerSquared = inner * inner
        let outerSquared = outer * outer

        for y in 0..<canvasSize {
            let dy = (Double(y) - centre) / scale
            for x in 0..<canvasSize {
                let dx = (Double(x) - centre) / scale
                let radiusSquared = dx * dx + dy * dy
                let offset = (y * canvasSize + x) * 4
                if radiusSquared < innerSquared - 1e-10 || radiusSquared > outerSquared + 1e-10 {
                    pixels[offset] = 255
                    pixels[offset + 1] = 255
                    pixels[offset + 2] = 255
                    pixels[offset + 3] = 255
                    continue
                }
                let value = sampleGray(
                    gray,
                    xMm: dx,
                    yMm: dy,
                    outerRadiusMm: geometry.outerRadiusMm,
                    family: geometry.family
                )
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 255
            }
        }
        return RasterImage(width: canvasSize, height: canvasSize, pixels: pixels)
    }

    /// 在给定盘面毫米坐标处采样图案（已按绘图环带裁切，环带外为白 255）。
    public static func sample(
        xMm: Double,
        yMm: Double,
        geometry: DiscGeometry,
        drawingStartSector: Int = 0,
        drawingEndSectorExclusive: Int = 0
    ) -> UInt8 {
        guard xMm.isFinite, yMm.isFinite else { return 255 }
        let parameters = CalibrationParameters(
            geometry: geometry,
            drawingStartSector: drawingStartSector,
            drawingEndSectorExclusive: drawingEndSectorExclusive
        )
        guard let gray = grayPixelsCache else { return 255 }
        let radiusSquared = xMm * xMm + yMm * yMm
        let inner = parameters.drawingInnerRadiusMm
        let outer = parameters.drawingOuterRadiusMm
        if radiusSquared < inner * inner - 1e-10 || radiusSquared > outer * outer + 1e-10 {
            return 255
        }
        return sampleGray(
            gray,
            xMm: xMm,
            yMm: yMm,
            outerRadiusMm: geometry.outerRadiusMm,
            family: geometry.family
        )
    }

    public static func sample(
        xMm: Double,
        yMm: Double,
        generation: CalibrationGenerationSnapshot
    ) -> UInt8 {
        sample(
            xMm: xMm,
            yMm: yMm,
            geometry: generation.geometry,
            drawingStartSector: generation.drawingStartSector,
            drawingEndSectorExclusive: generation.drawingEndSectorExclusive
        )
    }

    // MARK: - 资源加载

    private static let grayPixelsCache: [UInt8]? = try? loadGrayPixels()

    private static func loadReferenceImage() throws -> RasterImage {
        guard let url = Bundle.module.url(forResource: "target_slim", withExtension: "png") else {
            throw DiscError.io("缺少内置标定参考图案 target_slim.png。")
        }
        return try RasterImage.load(contentsOf: url)
    }

    static func loadGrayPixels() throws -> [UInt8] {
        let image = try loadReferenceImage()
        guard image.width == pixelSize, image.height == pixelSize else {
            throw DiscError.io("标定参考图案尺寸应为 \(pixelSize)×\(pixelSize)，实际 \(image.width)×\(image.height)。")
        }
        var gray = [UInt8](repeating: 255, count: pixelSize * pixelSize)
        // 原图三个颜色通道逐像素相同，取 R 即为灰度；透明图（不该出现）按白底合成。
        for index in 0..<(pixelSize * pixelSize) {
            let offset = index * 4
            let alpha = image.pixels[offset + 3]
            let red = image.pixels[offset]
            gray[index] = alpha == 255 ? red : 255
        }
        return gray
    }

    /// 采样原图的灰度。三种介质各自的像素约定与普通编码器相同。
    static func sampleGray(
        _ gray: [UInt8],
        xMm: Double,
        yMm: Double,
        outerRadiusMm: Double,
        family: DiscFamily
    ) -> UInt8 {
        guard xMm.isFinite, yMm.isFinite, outerRadiusMm.isFinite, outerRadiusMm > 0 else { return 255 }
        let centre = pixelCentre(family: family)
        let scale = centre / outerRadiusMm
        let x = centre + xMm * scale
        let y = centre + yMm * scale

        switch family {
        case .bluRay:
            // 蓝光取 floor 索引的像素中心。
            guard x >= 0, y >= 0, x < Double(pixelSize), y < Double(pixelSize) else { return 255 }
            return gray[Int(y) * pixelSize + Int(x)]
        case .cd:
            // CD 取四舍五入的最近像素（C# 的 Math.Round 是银行家舍入）。
            let nearestX = Int(x.rounded(.toNearestOrEven))
            let nearestY = Int(y.rounded(.toNearestOrEven))
            guard nearestX >= 0, nearestY >= 0,
                  nearestX < pixelSize, nearestY < pixelSize else { return 255 }
            return gray[nearestY * pixelSize + nearestX]
        case .dvd:
            // DVD 双线性；保留上游的权重乘法顺序，避免 127.5 阈值附近的舍入差异。
            guard x >= 0, y >= 0, x <= Double(pixelSize - 1), y <= Double(pixelSize - 1) else {
                return 255
            }
            let x0 = Int(x.rounded(.down))
            let y0 = Int(y.rounded(.down))
            let x1 = min(x0 + 1, pixelSize - 1)
            let y1 = min(y0 + 1, pixelSize - 1)
            let fx = x - Double(x0)
            let fy = y - Double(y0)
            let alpha00 = ((1 - fx) * (1 - fy)) * 255
            let alpha10 = (fx * (1 - fy)) * 255
            let alpha01 = ((1 - fx) * fy) * 255
            let alpha11 = (fx * fy) * 255
            let totalAlpha = alpha00 + alpha10 + alpha01 + alpha11
            let value = (Double(gray[y0 * pixelSize + x0]) * alpha00
                + Double(gray[y0 * pixelSize + x1]) * alpha10
                + Double(gray[y1 * pixelSize + x0]) * alpha01
                + Double(gray[y1 * pixelSize + x1]) * alpha11) * (1.0 / totalAlpha)
            return UInt8(min(max(value.rounded(), 0), 255))
        }
    }
}
