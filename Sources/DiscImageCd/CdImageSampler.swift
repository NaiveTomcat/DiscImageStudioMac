import DiscImageCore
import Foundation

/// 预计算的像素亮度表（Double）。
///
/// 双线性采样每个字节要取 4 个相邻像素、每个像素算一次 `0.2126R + 0.7152G + 0.0722B`。
/// 亮度只取决于源图，所以先整张算好：之后每个字节只剩 4 次查表 + 插值，
/// 采样耗时大约减半。数值与 `RasterImage.luminance` **逐位相同**（同一表达式、
/// 同一运算顺序），因此输出字节不变。
///
/// 用 `final class` 持有手动分配的内存，是为了让热点循环拿到裸指针（免边界检查），
/// 又不把对象变成值类型（值类型无法安全地在 `deinit` 里释放）。
final class CdLuminanceTable: @unchecked Sendable {
    let width: Int
    let height: Int
    private let storage: UnsafeMutablePointer<Double>

    /// 裸指针，只在表对象存活期间有效；调用方保证不越界。
    @inline(__always)
    var base: UnsafePointer<Double> { UnsafePointer(storage) }

    init(image: RasterImage) {
        let width = image.width
        let height = image.height
        self.width = width
        self.height = height
        let count = width * height
        storage = UnsafeMutablePointer<Double>.allocate(capacity: count)
        image.pixels.withUnsafeBufferPointer { pixels in
            for index in 0..<count {
                let offset = index * 4
                storage[index] = 0.2126 * Double(pixels[offset])
                    + 0.7152 * Double(pixels[offset + 1])
                    + 0.0722 * Double(pixels[offset + 2])
            }
        }
    }

    deinit {
        storage.deallocate()
    }

    /// 占用字节数（用于内存预算判断）。
    static func byteCount(width: Int, height: Int) -> Int {
        width * height * MemoryLayout<Double>.stride
    }
}

/// 按字节序号从源图取灰度。
///
/// 采样点由 `CdDiscParameters.imagePointFromByte` 给出（画布中心 = 盘心、CLV 螺旋角度）。
/// 采样方式按 `RasterImage` 的实际情况二选一：
///
/// - 源图已经是「不透明 + 纯黑白」时用**最近邻**：插值会把已经抖动好的黑白密度
///   抹成中间灰，图案读回后与原图不符；
/// - 其它情况用**双线性**：照片类输入的边缘更平滑，盘面灰调更接近原图。
///
/// 像素亮度会先预计算成表（见 `CdLuminanceTable`），超过内存预算的大图退回逐像素
/// 现算 —— 两条路径的数值逐位相同，只影响速度。
///
/// 采样结果只取决于「图片 + 几何 + 字节序号」，所以同一份输入每次生成的字节完全一致。
public struct CdImageSampler: Sendable {
    public let image: RasterImage
    public let parameters: CdDiscParameters

    /// 亮度表；源图太大（超出预算）时为 nil，走逐像素现算的慢路径。
    let luminanceTable: CdLuminanceTable?

    private let innerSquared: Double
    private let radiusSquaredRange: Double
    private let angleScale: Double
    private let innerRadiusMm: Double
    private let totalBytes: Double
    private let halfWidth: Double
    private let halfHeight: Double
    private let pixelScale: Double
    private let usesNearestNeighbour: Bool

    /// 亮度表的内存预算：64 MiB ≈ 8M 像素（2048×2048、4096×2048 都在内）。
    /// 更大的图直接现算，避免为一张 8192² 的图占掉半个 GB。
    public static let defaultLuminanceTableByteBudget = 64 * 1024 * 1024

    public init(image: RasterImage, parameters: CdDiscParameters) {
        self.init(
            image: image,
            parameters: parameters,
            luminanceTableByteBudget: CdImageSampler.defaultLuminanceTableByteBudget
        )
    }

    /// 内部入口：`luminanceTableByteBudget = 0` 可以强制走现算路径（测试两条路径等价）。
    init(image: RasterImage, parameters: CdDiscParameters, luminanceTableByteBudget: Int) {
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

        let estimated = CdLuminanceTable.byteCount(width: image.width, height: image.height)
        if estimated <= luminanceTableByteBudget {
            self.luminanceTable = CdLuminanceTable(image: image)
        } else {
            self.luminanceTable = nil
        }
    }

    /// 是否走最近邻采样（源图已是纯黑白时为 true）。
    public var isNearestNeighbour: Bool { usesNearestNeighbour }

    /// 是否用上了预计算亮度表（大图会退回现算）。
    public var usesLuminanceTable: Bool { luminanceTable != nil }

    /// 逻辑字节序号 → 源图灰度（0…255）。
    ///
    /// 序号越界时按源项目语义夹到两端（负数当 0、超过整盘当外圈）。
    @inline(__always)
    public func gray(atByte globalByte: Int) -> UInt8 {
        let fraction = min(max(Double(globalByte) / totalBytes, 0), 1)
        let radius = (innerSquared + fraction * radiusSquaredRange).squareRoot()
        let theta = angleScale * (radius - innerRadiusMm)
        let pixelRadius = pixelScale * radius
        let x = halfWidth + pixelRadius * cos(theta)
        let y = halfHeight + pixelRadius * sin(theta)
        return UInt8(min(max(luminance(atX: x, atY: y).rounded(), 0), 255))
    }

    /// 取灰度再按影调映射成调色板字节。`sampleIndex` 就是 `globalByte`。
    public func paletteByte(atByte globalByte: Int, tone: ToneProfile) -> UInt8 {
        CdToneMapping.map(
            gray: gray(atByte: globalByte),
            tone: tone,
            sampleIndex: Int64(globalByte)
        )
    }

    /// 连续坐标处的亮度。走亮度表时是 4 次查表 + 双线性插值；
    /// 没有亮度表时退回 `RasterImage` 的逐像素实现。两者数值逐位相同。
    @inline(__always)
    func luminance(atX x: Double, atY y: Double) -> Double {
        if let table = luminanceTable {
            let base = table.base
            let width = table.width
            let height = table.height
            if usesNearestNeighbour {
                let clampedX = min(max(Int(x.rounded()), 0), width - 1)
                let clampedY = min(max(Int(y.rounded()), 0), height - 1)
                return base[clampedY * width + clampedX]
            }
            let clampedX = min(max(x, 0), Double(width - 1))
            let clampedY = min(max(y, 0), Double(height - 1))
            let x0 = Int(clampedX)
            let y0 = Int(clampedY)
            let x1 = min(x0 + 1, width - 1)
            let y1 = min(y0 + 1, height - 1)
            let fx = clampedX - Double(x0)
            let fy = clampedY - Double(y0)
            let topLeft = base[y0 * width + x0]
            let topRight = base[y0 * width + x1]
            let bottomLeft = base[y1 * width + x0]
            let bottomRight = base[y1 * width + x1]
            let top = topLeft + (topRight - topLeft) * fx
            let bottom = bottomLeft + (bottomRight - bottomLeft) * fx
            return top + (bottom - top) * fy
        }

        if usesNearestNeighbour {
            return image.luminance(x: Int(x.rounded()), y: Int(y.rounded()))
        }
        return image.luminance(bilinearX: x, bilinearY: y)
    }
}
