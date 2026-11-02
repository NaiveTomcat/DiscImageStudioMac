import Foundation
import DiscImageCore

/// 蓝光 ISO 的旁写元数据（`format: bd-r-image-v1`）。
///
/// 有了它，重新打开成品镜像时不需要原始工程即可恢复：几何、绘图起止与半径、
/// 3T/6T 极性、影调、卷标、UDF 时间戳。CLI 与 GUI 输出使用同一份结构。
///
/// 注意：`sourceImage` 来自 `GenerationRequest` 之外的调用方信息；引擎只拿到
/// 已经解码的栅格，所以该字段可能为空字符串。
public struct BluRayISOMetadata: Codable, Sendable, Equatable {
    public static let formatName = DiscImageCore.bluRaySidecarSchema  // "bd-r-image-v1"

    public var format: String
    public var sourceImage: String
    public var outputIso: String
    public var isoBytes: Int64
    public var totalSectors: UInt32
    public var innerRadiusMm: Double
    public var outerRadiusMm: Double
    public var invertMapping: Bool
    public var tone: ToneProfile
    public var drawingStartSector: UInt32
    public var drawingEndSectorExclusive: UInt32
    public var drawingStartRadiusMm: Double
    public var drawingEndRadiusMm: Double
    public var volumeLabel: String
    public var dataDirectory: String?
    public var udfTimestamp: Date?
    public var generatedUtc: Date
    public var filesAtOuterRing: Bool

    public init(
        format: String = BluRayISOMetadata.formatName,
        sourceImage: String = "",
        outputIso: String,
        isoBytes: Int64,
        totalSectors: UInt32,
        innerRadiusMm: Double,
        outerRadiusMm: Double,
        invertMapping: Bool,
        tone: ToneProfile,
        drawingStartSector: UInt32,
        drawingEndSectorExclusive: UInt32,
        drawingStartRadiusMm: Double,
        drawingEndRadiusMm: Double,
        volumeLabel: String,
        dataDirectory: String?,
        udfTimestamp: Date?,
        generatedUtc: Date,
        filesAtOuterRing: Bool
    ) {
        self.format = format
        self.sourceImage = sourceImage
        self.outputIso = outputIso
        self.isoBytes = isoBytes
        self.totalSectors = totalSectors
        self.innerRadiusMm = innerRadiusMm
        self.outerRadiusMm = outerRadiusMm
        self.invertMapping = invertMapping
        self.tone = tone
        self.drawingStartSector = drawingStartSector
        self.drawingEndSectorExclusive = drawingEndSectorExclusive
        self.drawingStartRadiusMm = drawingStartRadiusMm
        self.drawingEndRadiusMm = drawingEndRadiusMm
        self.volumeLabel = volumeLabel
        self.dataDirectory = dataDirectory
        self.udfTimestamp = udfTimestamp
        self.generatedUtc = generatedUtc
        self.filesAtOuterRing = filesAtOuterRing
    }

    /// 旁写文件路径：`<outputBase>-bd-r-image-v1.json`（与 `GenerationRequest.outputBaseURL`
    /// 「不含扩展名的基础路径」约定一致）。
    public static func sidecarURL(forOutputBase base: URL) -> URL {
        let name = base.lastPathComponent + "-\(formatName).json"
        return base.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// 保存为 JSON（ISO 8601 时间、缩进、原子写入）。
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(self)
            try data.write(to: url, options: .atomic)
        } catch let error as DiscError {
            throw error
        } catch {
            throw DiscError.io("无法写入蓝光旁写元数据 \(url.lastPathComponent)：\(error.localizedDescription)")
        }
    }

    /// 读取旁写 JSON；格式标识不匹配或内容损坏时抛错。
    public static func load(from url: URL) throws -> BluRayISOMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let metadata = try decoder.decode(BluRayISOMetadata.self, from: Data(contentsOf: url))
            guard metadata.format == formatName else {
                throw DiscError.unsupported("旁写文件格式不是 \(formatName)：\(url.lastPathComponent)")
            }
            return metadata
        } catch let error as DiscError {
            throw error
        } catch {
            throw DiscError.io("无法读取蓝光旁写元数据 \(url.lastPathComponent)：\(error.localizedDescription)")
        }
    }
}
