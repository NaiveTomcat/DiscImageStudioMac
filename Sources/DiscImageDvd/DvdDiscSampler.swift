import DiscImageCore
import Foundation

/// 方形图片 ↔ 盘面毫米坐标的采样器。
///
/// 与源项目 `RasterImage.SampleDisc` 同一套约定（HANDOFF §2.1）：
/// 图心对盘心，`pixelRadius = (size/2) · r / outerRadiusMm`，y 轴向下翻转；
/// 越界当透明；二值不透明图用最近邻（不要再插值，否则抖动好的中调会被抹平），
/// 其余用按 alpha 加权的双线性。
///
/// 性能：尺寸与像素数组在 init 时就地缓存（避免每字节跨模块访问
/// `RasterImage` 的属性），整个 Block 的采样走预取的 `UnsafeBufferPointer`。
/// 数值路径与优化前逐位一致（相同的运算顺序与四舍五入）。
struct DvdDiscSampler: Sendable {
    let outerRadiusMm: Double

    private let pixels: [UInt8]
    private let width: Int
    private let height: Int
    /// 每毫米对应的像素数。
    private let pixelsPerMillimetre: Double
    private let useNearestNeighbour: Bool
    private let centreX: Double
    private let centreY: Double
    /// 整张图是否全不透明。是的话双线性可以省掉 alpha 归一化。
    private let isOpaque: Bool
    private let maxX: Double
    private let maxY: Double

    init(image: RasterImage, outerRadiusMm: Double) {
        pixels = image.pixels
        width = image.width
        height = image.height
        self.outerRadiusMm = outerRadiusMm
        let shorterSide = Double(min(image.width, image.height))
        pixelsPerMillimetre = (shorterSide - 1) / (2 * outerRadiusMm)
        centreX = Double(image.width - 1) / 2
        centreY = Double(image.height - 1) / 2
        maxX = Double(image.width - 1)
        maxY = Double(image.height - 1)
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

    /// 在像素缓冲区有效期内跑完整个 Block 的采样（省掉每字节一次属性访问）。
    @inline(__always)
    func withUnsafePixels<T>(_ body: (UnsafeBufferPointer<UInt8>) throws -> T) rethrows -> T {
        try pixels.withUnsafeBufferPointer(body)
    }

    /// 盘面坐标（mm，x 向右、y 向上）→（亮度 0…255，alpha 0…255）。
    /// 落在图外时返回 `(0, 0)`。
    @inline(__always)
    func sample(
        xMm: Double,
        yMm: Double,
        pixels buffer: UnsafeBufferPointer<UInt8>
    ) -> (luminance: UInt8, alpha: UInt8) {
        let pixelX = centreX + xMm * pixelsPerMillimetre
        let pixelY = centreY - yMm * pixelsPerMillimetre
        guard pixelX.isFinite, pixelY.isFinite,
              pixelX >= 0, pixelY >= 0, pixelX <= maxX, pixelY <= maxY else {
            return (0, 0)
        }

        if useNearestNeighbour {
            let x = min(max(Int((pixelX + 0.5).rounded(.down)), 0), width - 1)
            let y = min(max(Int((pixelY + 0.5).rounded(.down)), 0), height - 1)
            let offset = (y * width + x) * 4
            return (buffer[offset], 255)
        }

        let x0 = Int(pixelX.rounded(.down))
        let y0 = Int(pixelY.rounded(.down))
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let horizontal = pixelX - Double(x0)
        let vertical = pixelY - Double(y0)

        let rowStride = width * 4
        let offset00 = y0 * rowStride + x0 * 4
        let offset10 = y0 * rowStride + x1 * 4
        let offset01 = y1 * rowStride + x0 * 4
        let offset11 = y1 * rowStride + x1 * 4
        // 一个像素一次 32 位加载（RGBA 四字节一起），比 12 次字节加载省一半以上的访存指令；
        // 取值与后面的插值运算顺序完全不变，输出逐字节一致。
        guard let base = buffer.baseAddress else { return (0, 0) }
        let raw = UnsafeRawPointer(base)
        let word00 = raw.loadUnaligned(fromByteOffset: offset00, as: UInt32.self)
        let word10 = raw.loadUnaligned(fromByteOffset: offset10, as: UInt32.self)
        let word01 = raw.loadUnaligned(fromByteOffset: offset01, as: UInt32.self)
        let word11 = raw.loadUnaligned(fromByteOffset: offset11, as: UInt32.self)

        @inline(__always)
        func channel(_ word: UInt32, _ shift: UInt32) -> Double {
            Double((word >> shift) & 0xFF)
        }

        @inline(__always)
        func interpolate(_ p00: Double, _ p10: Double, _ p01: Double, _ p11: Double) -> Double {
            let top = p00 + (p10 - p00) * horizontal
            let bottom = p01 + (p11 - p01) * horizontal
            return top + (bottom - top) * vertical
        }

        if isOpaque {
            let red = interpolate(
                channel(word00, 0), channel(word10, 0),
                channel(word01, 0), channel(word11, 0)
            )
            let green = interpolate(
                channel(word00, 8), channel(word10, 8),
                channel(word01, 8), channel(word11, 8)
            )
            let blue = interpolate(
                channel(word00, 16), channel(word10, 16),
                channel(word01, 16), channel(word11, 16)
            )
            let luminance = (0.2126 * red + 0.7152 * green + 0.0722 * blue)
                .rounded(.toNearestOrAwayFromZero)
            return (UInt8(min(max(luminance, 0), 255)), 255)
        }

        var totalAlpha = 0.0
        var weightedRed = 0.0
        var weightedGreen = 0.0
        var weightedBlue = 0.0

        func accumulate(_ word: UInt32, _ weight: Double) {
            let alpha = Double((word >> 24) & 0xFF) / 255.0
            let weightedAlpha = weight * alpha
            totalAlpha += weightedAlpha
            guard alpha > 0 else { return }
            // 像素是预乘 alpha 的，先还原成直通颜色再按源项目的口径加权。
            let unpremultiply = 1.0 / alpha
            weightedRed += weightedAlpha * channel(word, 0) * unpremultiply
            weightedGreen += weightedAlpha * channel(word, 8) * unpremultiply
            weightedBlue += weightedAlpha * channel(word, 16) * unpremultiply
        }

        accumulate(word00, (1 - horizontal) * (1 - vertical))
        accumulate(word10, horizontal * (1 - vertical))
        accumulate(word01, (1 - horizontal) * vertical)
        accumulate(word11, horizontal * vertical)

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
}

/// 影调判定的本地快路径。
///
/// `ToneProfile.useWhite` 在 Core 里（跨模块、非 `@inlinable`），每字节都调用
/// 其中几个小函数很贵。这里在 init 时把「灰度 → 调整后灰度」预计算成 256 项，
/// 并把抖动哈希按**完全相同的运算顺序**内联；结果与 Core 的实现逐位一致。
struct DvdToneDecider: Sendable {
    private let legacy: Bool
    private let strength: Double
    private let adjusted: [Double]

    init(tone: ToneProfile) {
        legacy = tone.isLegacyBinary
        strength = min(max(tone.ditherStrength, 0), 1)
        var table = [Double](repeating: 0, count: 256)
        for value in 0...255 {
            table[value] = Double(tone.adjustedGray(UInt8(value)))
        }
        adjusted = table
    }

    @inline(__always)
    func useWhite(_ gray: UInt8, sampleIndex: Int64) -> Bool {
        if legacy {
            return Double(gray) >= 128
        }
        let shifted = 128 + strength * 255.0 * (DvdToneDecider.phase(sampleIndex) - 0.5)
        return adjusted[Int(gray)] >= shifted
    }

    /// 与 `DiscImageCore.ToneDither.phase` 相同的哈希与运算顺序。
    @inline(__always)
    static func phase(_ sampleIndex: Int64) -> Double {
        var value = UInt32(truncatingIfNeeded: sampleIndex) &* 2_654_435_761
        value ^= value >> 16
        value &*= 0x7FEB_352D
        value ^= value >> 15
        value &*= 0x846C_A68B
        value ^= value >> 16
        return Double(value) / 4_294_967_296.0
    }
}
