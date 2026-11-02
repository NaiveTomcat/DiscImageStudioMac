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
    /// 因此这个缓存不改变任何字节，只是避免重复做三角运算。
    public func fillPayload(firstSector: UInt32, into payload: inout [UInt8]) throws {
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

        for index in 0..<order.count {
            let payloadIndex = order[index]
            let channel = clusterBase + offsets[payloadIndex]
            let sectorPosition = channel / BluRaySpec.channelBitsPerSector
            let point = try geometry.trackPoint(sectorPosition: sectorPosition)
            let px = halfWidth + point.xMm * scale
            let py = halfHeight - point.yMm * scale
            if px < 0 || py < 0 || px >= Double(width) || py >= Double(height) {
                payload[payloadIndex] = lightByte
                continue
            }
            let ix = Int(px)
            let iy = Int(py)
            let pixel = iy * width + ix
            if pixel != cachedPixel {
                cachedPixel = pixel
                cachedByte = binary[pixel] < BluRayRunLengthMapping.threshold ? darkByte : lightByte
            }
            payload[payloadIndex] = cachedByte
        }
    }

    /// 一步生成一簇 ISO 用户字节：host payload XOR 簇内共享的扰码掩码。
    public func scrambledCluster(firstSector: UInt32) throws -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: BluRaySpec.payloadBytesPerCluster)
        try fillPayload(firstSector: firstSector, into: &payload)
        let psn = BluRaySpec.firstLayer0PhysicalSector &+ firstSector
        let mask = BluRayScrambler.mask(physicalSectorNumber: psn, length: BluRaySpec.bytesPerSector)
        var output = [UInt8](repeating: 0, count: BluRaySpec.payloadBytesPerCluster)
        for sector in 0..<BluRaySpec.sectorsPerCluster {
            let base = sector * BluRaySpec.bytesPerSector
            for index in 0..<BluRaySpec.bytesPerSector {
                output[base + index] = payload[base + index] ^ mask[index]
            }
        }
        return output
    }
}
