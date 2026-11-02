import DiscImageCore
import Foundation

/// 按字节序号从源图取灰度。
///
/// 采样点由 `CdDiscParameters.imagePointFromByte` 给出（画布中心 = 盘心、CLV 螺旋角度）。
/// 采样方式按 `RasterImage` 的实际情况二选一：
///
/// - 源图已经是「不透明 + 纯黑白」时用**最近邻**：插值会把已经抖动好的黑白密度
///   抹成中间灰，图案读回后与原图不符；
/// - 其它情况用**双线性**：照片类输入的边缘更平滑，盘面灰调更接近原图。
///
/// 采样结果只取决于「图片 + 几何 + 字节序号」，所以同一份输入每次生成的字节完全一致。
public struct CdImageSampler: Sendable {
    public let image: RasterImage
    public let parameters: CdDiscParameters

    private let innerSquared: Double
    private let radiusSquaredRange: Double
    private let angleScale: Double
    private let innerRadiusMm: Double
    private let totalBytes: Double
    private let halfWidth: Double
    private let halfHeight: Double
    private let pixelScale: Double
    private let usesNearestNeighbour: Bool

    public init(image: RasterImage, parameters: CdDiscParameters) {
        self.image = image
        self.parameters = parameters
        self.innerSquared = parameters.innerRadiusMm * parameters.innerRadiusMm
        self.radiusSquaredRange = parameters.radiusSquaredRange
        self.angleScale = parameters.angleScale
        self.innerRadiusMm = parameters.innerRadiusMm
        self.totalBytes = Double(parameters.totalBytes)
        let halfExtent = Double(min(image.width, image.height)) / 2.0
        self.halfWidth = Double(image.width) / 2.0
        self.halfHeight = Double(image.height) / 2.0
        self.pixelScale = halfExtent / parameters.imageOuterRadiusMm
        self.usesNearestNeighbour = image.isOpaqueBinaryGrayscale
    }

    /// 是否走最近邻采样（源图已是纯黑白时为 true）。
    public var isNearestNeighbour: Bool { usesNearestNeighbour }

    /// 逻辑字节序号 → 源图灰度（0…255）。
    ///
    /// 序号越界时按源项目语义夹到两端（负数当 0、超过整盘当外圈）。
    public func gray(atByte globalByte: Int) -> UInt8 {
        let fraction = min(max(Double(globalByte) / totalBytes, 0), 1)
        let radius = (innerSquared + fraction * radiusSquaredRange).squareRoot()
        let theta = angleScale * (radius - innerRadiusMm)
        let pixelRadius = pixelScale * radius
        let x = halfWidth + pixelRadius * cos(theta)
        let y = halfHeight + pixelRadius * sin(theta)

        let luminance: Double
        if usesNearestNeighbour {
            luminance = image.luminance(x: Int(x.rounded()), y: Int(y.rounded()))
        } else {
            luminance = image.luminance(bilinearX: x, bilinearY: y)
        }
        return UInt8(min(max(luminance.rounded(), 0), 255))
    }

    /// 取灰度再按影调映射成调色板字节。`sampleIndex` 就是 `globalByte`。
    public func paletteByte(atByte globalByte: Int, tone: ToneProfile) -> UInt8 {
        CdToneMapping.map(
            gray: gray(atByte: globalByte),
            tone: tone,
            sampleIndex: Int64(globalByte)
        )
    }
}
