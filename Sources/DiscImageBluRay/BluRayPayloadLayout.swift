import Foundation
import DiscImageCore

/// 一个 payload 字节在 LDC 交织 + BIS 复用之后的名义物理位置。
///
/// `nominalChannelBitPosition` 由 2:3 调制率计算（含 DC 插入、同步帧与 run-in），
/// 是**名义**字节中点：变长的 17PP 码字意味着它不是精确的通道位边界，
/// 更不代表预测出的光学 mark 位置。
public struct BluRayPayloadPosition: Sendable, Equatable {
    public let sector: UInt32
    public let byteOffset: Int
    public let physicalSectorNumber: UInt32
    public let recordingFrame: Int
    public let ldcColumn: Int
    public let eccColumn: Int
    public let nominalChannelBitPosition: Double
    public let radiusMm: Double
    public let angleRadians: Double

    public var xMm: Double { radiusMm * cos(angleRadians) }
    public var yMm: Double { radiusMm * sin(angleRadians) }

    public init(
        sector: UInt32,
        byteOffset: Int,
        physicalSectorNumber: UInt32,
        recordingFrame: Int,
        ldcColumn: Int,
        eccColumn: Int,
        nominalChannelBitPosition: Double,
        radiusMm: Double,
        angleRadians: Double
    ) {
        self.sector = sector
        self.byteOffset = byteOffset
        self.physicalSectorNumber = physicalSectorNumber
        self.recordingFrame = recordingFrame
        self.ldcColumn = ldcColumn
        self.eccColumn = eccColumn
        self.nominalChannelBitPosition = nominalChannelBitPosition
        self.radiusMm = radiusMm
        self.angleRadians = angleRadians
    }
}

/// 用户 payload 字节 ↔ LDC 交织后物理位置的映射（与 `BluRayImageMapping.cs` 一致）。
///
/// 每簇 65,536 个 payload 字节落在 304 × 216 的 LDC 网格里（余下 128 个位置是 EDC），
/// 再由行/列交织散到 496 帧 × 152 列；BIS 每 38 个 LDC 字节插 1 字节，
/// 于是得到 496 × 155 的 ECC 帧。
public enum BluRayPayloadLayout {
    /// 每簇内部的通道位偏移（相对簇起始的 recording unit）。按 payload 顺序排列。
    public static let channelOffsets: [Double] = buildChannelOffsets()
    /// 按通道位偏移升序排列的 payload 下标（顺序取样用）。
    public static let physicalOrder: [Int] = channelOffsets.indices.sorted { channelOffsets[$0] < channelOffsets[$1] }

    /// 计算一个 payload 字节的位置；`sector` 是盘内逻辑扇区。
    public static func position(
        sector: UInt32,
        byteOffset: Int,
        firstPhysicalSector: UInt32 = BluRaySpec.firstLayer0PhysicalSector,
        geometry: BluRayTrackGeometry? = nil
    ) throws -> BluRayPayloadPosition {
        guard byteOffset >= 0, byteOffset < BluRaySpec.bytesPerSector else {
            throw DiscError.encoding("payload 字节偏移必须在 0…2047（当前 \(byteOffset)）")
        }
        let clusterBase = (sector / UInt32(BluRaySpec.sectorsPerCluster))
            * UInt32(BluRaySpec.channelBitsPerRecordingUnit)
        let offset = channelOffsets[Int(sector % UInt32(BluRaySpec.sectorsPerCluster)) * BluRaySpec.bytesPerSector + byteOffset]
        let channel = Double(clusterBase) + offset
        let sectorPosition = channel / BluRaySpec.channelBitsPerSector
        let point = try geometry?.trackPoint(sectorPosition: sectorPosition)
        return BluRayPayloadPosition(
            sector: sector,
            byteOffset: byteOffset,
            physicalSectorNumber: firstPhysicalSector &+ sector,
            recordingFrame: recordingFrame(sector: sector, byteOffset: byteOffset),
            ldcColumn: ldcColumn(sector: sector, byteOffset: byteOffset),
            eccColumn: eccColumn(sector: sector, byteOffset: byteOffset),
            nominalChannelBitPosition: channel,
            radiusMm: point?.radiusMm ?? 0,
            angleRadians: point?.angleRadians ?? 0
        )
    }

    /// payload 字段到 (column, row) 的拆分：`serial = (sector % 32) × 2052 + offset`。
    public static func grid(sector: UInt32, byteOffset: Int) -> (column: Int, row: Int) {
        let serial = Int(sector % UInt32(BluRaySpec.sectorsPerCluster)) * BluRaySpec.dataFrameBytes + byteOffset
        return (serial / BluRaySpec.ldcDataBytes, serial % BluRaySpec.ldcDataBytes)
    }

    public static func recordingFrame(sector: UInt32, byteOffset: Int) -> Int {
        let (column, row) = grid(sector: sector, byteOffset: byteOffset)
        return 2 * row + column % 2
    }

    public static func ldcColumn(sector: UInt32, byteOffset: Int) -> Int {
        let (column, row) = grid(sector: sector, byteOffset: byteOffset)
        return (column / 2 + 152 - (row * 3) % 152) % 152
    }

    /// ECC 帧内列号：BIS 在前三组 38 个 LDC 字节之后各插一字节。
    public static func eccColumn(sector: UInt32, byteOffset: Int) -> Int {
        let column = ldcColumn(sector: sector, byteOffset: byteOffset)
        return column + column / 38
    }

    /// 名义通道位位置（相对整簇 recording unit 的起始）。
    public static func channelOffset(sector: UInt32, byteOffset: Int) -> Double {
        channelOffsets[Int(sector % UInt32(BluRaySpec.sectorsPerCluster)) * BluRaySpec.bytesPerSector + byteOffset]
    }

    static func buildChannelOffsets() -> [Double] {
        var offsets = [Double](repeating: 0, count: BluRaySpec.payloadBytesPerCluster)
        for sector in 0..<BluRaySpec.sectorsPerCluster {
            for index in 0..<BluRaySpec.bytesPerSector {
                let serial = sector * BluRaySpec.dataFrameBytes + index
                let column = serial / BluRaySpec.ldcDataBytes
                let row = serial % BluRaySpec.ldcDataBytes
                let frame = 2 * row + column % 2
                let ldc = (column / 2 + 152 - (row * 3) % 152) % 152
                let ecc = ldc + ldc / 38
                let midpoint = ecc * 8 + 4
                let dcBits = midpoint < 25 ? 0 : 1 + (midpoint - 25) / 45
                offsets[sector * BluRaySpec.bytesPerSector + index] =
                    Double(BluRaySpec.runInChannelBits + frame * BluRaySpec.channelBitsPerFrame + 30)
                    + Double(midpoint + dcBits) * 1.5
            }
        }
        return offsets
    }
}
