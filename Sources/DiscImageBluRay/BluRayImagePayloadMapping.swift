import Foundation
import DiscImageCore

/// 源图 → 扰码域 payload 字节的映射。
///
/// 流程（与源项目 `BluRayToneMapping` + `BluRayImagePayloadMapping` 一致）：
/// 1. 在**源图分辨率**上一次性二值化（`ToneProfile`：sRGB 线性化 → 亮度 → 抖动 → 128 阈值）；
/// 2. 每个 payload 字节按 LDC 交织后的名义物理位置取样（最近像素中心）；
/// 3. 暗部 → `0xAA`（偏 3T），亮部 → `0x44`（偏 6T），`invert` 交换两端。
///
/// 图片保持宽高比、最长边对应盘片外径，图像外区域为白色（亮）。
/// 位置只覆盖用户 payload 字节；EDC、LDC/BIS 校验、同步、DC 控制位与 run-in/out
/// 都由编码链自行生成，不能被图片任意覆盖。
///
/// ## 取样加速（输出逐字节不变）
///
/// 位置表在同一簇内只依赖「相对通道偏移」：`sector = clusterIndex × 32 + offset / 30066.75`。
/// 因此每簇先用 `trackPoint` 精确算一张 x/y 查找表（步长 512 通道位 ≈ 0.038 mm），
/// 再用线性插值求出每个 payload 字节的像素坐标 —— 把每簇的 Newton/asinh 调用从
/// 65,536 次降到约 1,900 次。
///
/// 插值误差有解析上界（曲率 ≤ 1/内半径，线性插值误差 ≤ h²·|f″|/8）。只要像素坐标
/// 落在整数边界一个 `epsilon` 之内，就回退到精确 `trackPoint` 重算，因此**像素索引
/// 与逐字节精确取样完全一致**；`fillPayloadExact` 保留为测试用的参考实现。
public struct BluRayImagePayloadMapping {
    public let width: Int
    public let height: Int
    /// 源图分辨率的二值栅格：0（暗）或 255（亮）。
    public let binary: [UInt8]
    public let outerRadiusMm: Double
    public let scale: Double
    public let geometry: BluRayTrackGeometry
    public let runLength: BluRayRunLengthMapping
    public let totalSectors: Int

    /// 插值回退阈值（像素）：远大于解析误差上界，见 `init`。
    let epsilonPixels: Double

    public init(
        image: RasterImage,
        tone: ToneProfile,
        geometry: BluRayTrackGeometry,
        invert: Bool
    ) {
        let toneProfile = tone.normalized()
        width = image.width
        height = image.height
        outerRadiusMm = geometry.outerRadiusMm
        self.geometry = geometry
        totalSectors = geometry.totalSectors
        runLength = BluRayRunLengthMapping(invert: invert)
        scale = Double(max(image.width, image.height)) / (2 * geometry.outerRadiusMm)

        // 线性插值误差上界：x(s)、y(s) 的曲率不超过 1/内半径（阿基米德螺旋），
        // 每步 h 的偏差 ≤ h²·κ/8；再换算到像素坐标并留 8× 余量。
        let stepMm = PayloadSamplingTable.stepChannelBits * BluRaySpec.channelBitLengthNm * 1e-6
        let curvaturePerMm = 1.0 / geometry.innerRadiusMm
        let errorPixels = curvaturePerMm * stepMm * stepMm / 8 * scale
        epsilonPixels = max(1e-4, errorPixels * 8)

        var values = [UInt8](repeating: 0, count: image.width * image.height)
        var sampleIndex: Int64 = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let luminance = image.luminance(x: x, y: y)
                let gray = UInt8(min(max(luminance.rounded(), 0), 255))
                values[y * image.width + x] = toneProfile.useWhite(gray, sampleIndex: sampleIndex) ? 255 : 0
                sampleIndex += 1
            }
        }
        binary = values
    }

    /// 填充一整簇的 **host 域** payload 字节（尚未 XOR 加扰掩码）。
    ///
    /// 按通道位偏移升序走一遍物理位置，并缓存「同一像素」的映射结果：
    /// 由于二值化已经发生在源图分辨率上，同一像素的取样结果完全相同，
    /// 因此这个缓存不改变任何字节，只是避免重复查表。
    public func fillPayload(firstSector: UInt32, into payload: inout [UInt8]) throws {
        precondition(payload.count == BluRaySpec.payloadBytesPerCluster, "簇 payload 必须是 65,536 字节")
        let clusterIndex = Int(firstSector / UInt32(BluRaySpec.sectorsPerCluster))
        let clusterBaseChannel = Double(clusterIndex * BluRaySpec.channelBitsPerRecordingUnit)
        let layout = PayloadSamplingTable.shared
        let offsets = BluRayPayloadLayout.channelOffsets
        let order = BluRayPayloadLayout.physicalOrder
        let darkByte = runLength.map(gray: 0)
        let lightByte = runLength.map(gray: 255)
        let halfWidth = Double(width) / 2
        let halfHeight = Double(height) / 2
        let widthLimit = Double(width) - epsilonPixels
        let heightLimit = Double(height) - epsilonPixels

        // 每簇一张精确位置表：x/y 已换算到像素坐标。
        let tableCount = layout.tableCount
        var pxTable = [Double](repeating: 0, count: tableCount)
        var pyTable = [Double](repeating: 0, count: tableCount)
        for node in 0..<tableCount {
            let channel = clusterBaseChannel + Double(node) * PayloadSamplingTable.stepChannelBits
            let point = try geometry.trackPoint(sectorPosition: channel / BluRaySpec.channelBitsPerSector)
            pxTable[node] = halfWidth + point.xMm * scale
            pyTable[node] = halfHeight - point.yMm * scale
        }

        let gridIndices = layout.gridIndices
        let gridFractions = layout.gridFractions
        var cachedPixel = -1
        var cachedByte = lightByte

        try payload.withUnsafeMutableBufferPointer { buffer in
            for slot in 0..<order.count {
                let payloadIndex = order[slot]
                let grid = Int(gridIndices[slot])
                let fraction = gridFractions[slot]
                var px = pxTable[grid] + (pxTable[grid + 1] - pxTable[grid]) * fraction
                var py = pyTable[grid] + (pyTable[grid + 1] - pyTable[grid]) * fraction

                // 靠近像素边界 / 图像边界时用精确几何重算，保证像素索引与参考实现一致。
                let nearBoundary = px < epsilonPixels || py < epsilonPixels
                    || px > widthLimit || py > heightLimit
                    || abs(px - px.rounded()) < epsilonPixels
                    || abs(py - py.rounded()) < epsilonPixels
                if nearBoundary {
                    let channel = clusterBaseChannel + offsets[payloadIndex]
                    let point = try geometry.trackPoint(sectorPosition: channel / BluRaySpec.channelBitsPerSector)
                    px = halfWidth + point.xMm * scale
                    py = halfHeight - point.yMm * scale
                }

                if px < 0 || py < 0 || px >= Double(width) || py >= Double(height) {
                    buffer[payloadIndex] = lightByte
                    continue
                }
                let ix = Int(px)
                let iy = Int(py)
                let pixel = iy * width + ix
                if pixel != cachedPixel {
                    cachedPixel = pixel
                    cachedByte = binary[pixel] < BluRayRunLengthMapping.threshold ? darkByte : lightByte
                }
                buffer[payloadIndex] = cachedByte
            }
        }
    }

    /// 参考实现：每个 payload 字节都调用精确 `trackPoint`。
    ///
    /// 仅用于测试与回归对拍；生产路径走 `fillPayload` 的查找表 + 插值 + 边界回退。
    public func fillPayloadExact(firstSector: UInt32, into payload: inout [UInt8]) throws {
        precondition(payload.count == BluRaySpec.payloadBytesPerCluster, "簇 payload 必须是 65,536 字节")
        let clusterBase = Double((firstSector / UInt32(BluRaySpec.sectorsPerCluster))
            * UInt32(BluRaySpec.channelBitsPerRecordingUnit))
        let offsets = BluRayPayloadLayout.channelOffsets
        let order = BluRayPayloadLayout.physicalOrder
        let darkByte = runLength.map(gray: 0)
        let lightByte = runLength.map(gray: 255)
        let halfWidth = Double(width) / 2
        let halfHeight = Double(height) / 2
        var cachedPixel = -1
        var cachedByte = lightByte

        try payload.withUnsafeMutableBufferPointer { buffer in
            for slot in 0..<order.count {
                let payloadIndex = order[slot]
                let channel = clusterBase + offsets[payloadIndex]
                let point = try geometry.trackPoint(sectorPosition: channel / BluRaySpec.channelBitsPerSector)
                let px = halfWidth + point.xMm * scale
                let py = halfHeight - point.yMm * scale
                if px < 0 || py < 0 || px >= Double(width) || py >= Double(height) {
                    buffer[payloadIndex] = lightByte
                    continue
                }
                let ix = Int(px)
                let iy = Int(py)
                let pixel = iy * width + ix
                if pixel != cachedPixel {
                    cachedPixel = pixel
                    cachedByte = binary[pixel] < BluRayRunLengthMapping.threshold ? darkByte : lightByte
                }
                buffer[payloadIndex] = cachedByte
            }
        }
    }

    /// 一步生成一簇 ISO 用户字节：host payload XOR 簇内共享的扰码掩码。
    ///
    /// 掩码只依赖簇首 PSN（低 5 位不参与种子），因此每簇可从常量独立重建，
    /// 与串行/并行、簇顺序无关。
    public func scrambledCluster(firstSector: UInt32) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: BluRaySpec.payloadBytesPerCluster)
        try fillPayload(firstSector: firstSector, into: &output)
        let psn = BluRaySpec.firstLayer0PhysicalSector &+ firstSector
        let mask = BluRayScrambler.mask(physicalSectorNumber: psn, length: BluRaySpec.bytesPerSector)
        output.withUnsafeMutableBufferPointer { buffer in
            for sector in 0..<BluRaySpec.sectorsPerCluster {
                let base = sector * BluRaySpec.bytesPerSector
                for index in 0..<BluRaySpec.bytesPerSector {
                    buffer[base + index] ^= mask[index]
                }
            }
        }
        return output
    }
}

/// 固定 payload 布局 → 查找表下标的预计算（与盘片、图像无关，进程内只算一次）。
private enum PayloadSamplingTable {
    /// 查找表步长（通道位）。512 位 ≈ 0.038 mm ≈ 0.5–1 个图像像素。
    static let stepChannelBits: Double = 512

    struct Layout {
        let tableCount: Int
        /// 每个物理序 payload 字节对应的查找表下标。
        let gridIndices: [Int32]
        /// 下标内的小数部分（0…1）。
        let gridFractions: [Double]
    }

    static let shared: Layout = build()

    private static func build() -> Layout {
        let offsets = BluRayPayloadLayout.channelOffsets
        let order = BluRayPayloadLayout.physicalOrder
        var indices = [Int32](repeating: 0, count: order.count)
        var fractions = [Double](repeating: 0, count: order.count)
        for slot in 0..<order.count {
            let grid = offsets[order[slot]] / stepChannelBits
            let base = grid.rounded(.down)
            indices[slot] = Int32(base)
            fractions[slot] = grid - base
        }
        let maximum = offsets.max() ?? 0
        let tableCount = Int((maximum / stepChannelBits).rounded(.up)) + 2
        return Layout(tableCount: tableCount, gridIndices: indices, gridFractions: fractions)
    }
}
