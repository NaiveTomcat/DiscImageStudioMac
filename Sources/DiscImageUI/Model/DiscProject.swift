import DiscImageCore
import Foundation

/// 设计页的一个图层：一张图片相对盘心的物理放置。
///
/// 语义照搬源项目（`ProjectLayer`）：位移单位毫米、+x 向右、+y **向下**；
/// 旋转单位为度、顺时针为正；缩放是「导入时按内容环直径适配后」的倍数。
public struct DesignLayer: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var imagePath: String
    public var visible: Bool
    public var translateXMm: Double
    public var translateYMm: Double
    public var rotationDeg: Double
    public var scale: Double

    public init(
        id: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""),
        name: String,
        imagePath: String,
        visible: Bool = true,
        translateXMm: Double = 0,
        translateYMm: Double = 0,
        rotationDeg: Double = 0,
        scale: Double = 1
    ) {
        self.id = id
        self.name = name
        self.imagePath = imagePath
        self.visible = visible
        self.translateXMm = translateXMm
        self.translateYMm = translateYMm
        self.rotationDeg = rotationDeg
        self.scale = scale
    }

    /// 缩放的面板显示值（百分比）。
    public var scalePercent: Double {
        get { scale * 100 }
        set { scale = newValue / 100 }
    }

    public var imageURL: URL { URL(fileURLWithPath: imagePath) }

    private enum CodingKeys: String, CodingKey {
        case id, name, imagePath, visible
        case translateXMm, translateYMm, rotationDeg, scale
    }

    /// 旧工程可能缺字段：按「可见、居中、无旋转、100%」补齐，而不是拒绝打开。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "图层"
        imagePath = try container.decodeIfPresent(String.self, forKey: .imagePath) ?? ""
        visible = try container.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        translateXMm = try container.decodeIfPresent(Double.self, forKey: .translateXMm) ?? 0
        translateYMm = try container.decodeIfPresent(Double.self, forKey: .translateYMm) ?? 0
        rotationDeg = try container.decodeIfPresent(Double.self, forKey: .rotationDeg) ?? 0
        scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1
    }
}

/// 导出设置：写到哪里、是否旁写 `.cue`、数据盘目录、卷标、是否交织。
public struct ProjectOutputs: Codable, Equatable, Sendable {
    public var outputPath: String
    public var writeCue: Bool
    public var dataDirectory: String
    public var volumeLabel: String
    public var interleave: Bool
    public var filesAtOuterRing: Bool

    public init(
        outputPath: String = "",
        writeCue: Bool = true,
        dataDirectory: String = "",
        volumeLabel: String = "DISC_IMAGE",
        interleave: Bool = true,
        filesAtOuterRing: Bool = false
    ) {
        self.outputPath = outputPath
        self.writeCue = writeCue
        self.dataDirectory = dataDirectory
        self.volumeLabel = volumeLabel
        self.interleave = interleave
        self.filesAtOuterRing = filesAtOuterRing
    }

    /// 数据盘模式：目录非空即视为要往盘里放文件。
    public var hasDataDirectory: Bool {
        !dataDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case outputPath, writeCue, dataDirectory, volumeLabel, interleave, filesAtOuterRing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outputPath = try container.decodeIfPresent(String.self, forKey: .outputPath) ?? ""
        writeCue = try container.decodeIfPresent(Bool.self, forKey: .writeCue) ?? true
        dataDirectory = try container.decodeIfPresent(String.self, forKey: .dataDirectory) ?? ""
        volumeLabel = try container.decodeIfPresent(String.self, forKey: .volumeLabel) ?? "DISC_IMAGE"
        interleave = try container.decodeIfPresent(Bool.self, forKey: .interleave) ?? true
        filesAtOuterRing = try container.decodeIfPresent(Bool.self, forKey: .filesAtOuterRing) ?? false
    }
}

/// 只对蓝光有意义的设置：3T/6T 映射极性。与 `ToneProfile` 分开是刻意的 ——
/// 影调决定「灰度 → 位」，极性决定「位 → 哪一类游程」。
public struct BluRaySettings: Codable, Equatable, Sendable {
    public var invertMapping: Bool

    public init(invertMapping: Bool = false) {
        self.invertMapping = invertMapping
    }

    private enum CodingKeys: String, CodingKey { case invertMapping }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        invertMapping = try container.decodeIfPresent(Bool.self, forKey: .invertMapping) ?? false
    }
}

/// `.discproj` 工程文件（JSON、camelCase、schemaVersion 2）。
///
/// 与源项目 `ProjectDocument` 对齐：
/// `name / discFamily / geometry / layers / outputs / calibrationSessionPath /
/// thumbnailPngBase64 / createdUtc / modifiedUtc / tone / bluRay`。
///
/// 兼容策略：schemaVersion 1（只有 CD/DVD）直接读；缺 `tone` 时保留 `nil`
/// （UI 用默认影调，保存时补齐）；缺 `bluRay` 时按不反转处理。
public struct DiscProject: Codable, Equatable, Sendable {
    /// 当前写出的 schema 版本。
    public static let currentSchemaVersion = 2
    /// 旧版（只有 CD/DVD）。
    public static let legacySchemaVersion = 1
    /// 文件扩展名（不带点）。
    public static let fileExtension = "discproj"
    /// 缩略图 base64 上限（512 KiB），挡住病态工程把 JSON 撑爆。
    public static let maxThumbnailBase64Length = 512 * 1024

    public var schemaVersion: Int
    public var name: String
    public var discFamily: DiscFamily
    public var geometry: DiscGeometry
    public var layers: [DesignLayer]
    public var outputs: ProjectOutputs
    public var calibrationSessionPath: String?
    public var thumbnailPngBase64: String?
    public var createdUtc: Date
    public var modifiedUtc: Date
    public var tone: ToneProfile?
    public var bluRay: BluRaySettings?

    public init(
        schemaVersion: Int = DiscProject.currentSchemaVersion,
        name: String,
        discFamily: DiscFamily,
        geometry: DiscGeometry,
        layers: [DesignLayer] = [],
        outputs: ProjectOutputs = ProjectOutputs(),
        calibrationSessionPath: String? = nil,
        thumbnailPngBase64: String? = nil,
        createdUtc: Date = Date(),
        modifiedUtc: Date = Date(),
        tone: ToneProfile? = .default,
        bluRay: BluRaySettings? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.discFamily = discFamily
        self.geometry = geometry
        self.layers = layers
        self.outputs = outputs
        self.calibrationSessionPath = calibrationSessionPath
        self.thumbnailPngBase64 = thumbnailPngBase64
        self.createdUtc = createdUtc
        self.modifiedUtc = modifiedUtc
        self.tone = tone
        self.bluRay = bluRay
    }

    // MARK: - 便捷派生量

    public var familyLabel: String { discFamily.displayNameZH }

    /// 画布外半径（mm）：设计画布中心 = 盘心，半宽对应这个半径。
    public var canvasOuterRadiusMm: Double {
        DiscPreset.projectionRadius(for: discFamily)
    }

    /// 影调（缺省时用新工程默认值）。
    public var effectiveTone: ToneProfile { tone ?? .default }

    /// 蓝光极性（缺省不反转）。
    public var effectiveInvertMapping: Bool { bluRay?.invertMapping ?? false }

    /// 由输出路径扩展名推断的输出格式，推断不出时按介质默认。
    public var outputFormat: GenerationOutputFormat {
        let ext = URL(fileURLWithPath: outputs.outputPath).pathExtension.lowercased()
        if let format = GenerationOutputFormat(rawValue: ext) {
            return format
        }
        return discFamily == .cd ? .wav : .iso
    }

    /// 该介质的候选输出格式。
    public var availableFormats: [GenerationOutputFormat] {
        GenerationOutputFormat.options(for: discFamily)
    }

    // MARK: - 校验

    /// 保存/打开前校验。错误信息全部是可直接展示的中文。
    public func validate() throws {
        guard schemaVersion == Self.legacySchemaVersion || schemaVersion == Self.currentSchemaVersion else {
            throw DiscError.invalidGeometry(
                "不支持 schemaVersion=\(schemaVersion)；当前支持 \(Self.legacySchemaVersion) 与 \(Self.currentSchemaVersion)。"
            )
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DiscError.invalidGeometry("工程名不能为空。")
        }
        guard discFamily == geometry.family else {
            throw DiscError.invalidGeometry(
                "discFamily（\(discFamily.rawValue)）与 geometry.family（\(geometry.family.rawValue)）不一致。"
            )
        }
        try geometry.validate()
        if schemaVersion == Self.legacySchemaVersion, discFamily == .bluRay {
            throw DiscError.invalidGeometry("schemaVersion 1 只包含 CD/DVD 工程，不能声明蓝光。")
        }
        if discFamily != .bluRay, bluRay != nil {
            throw DiscError.unsupported("bluRay 设置只用于蓝光工程。")
        }
        if let tone {
            try tone.validate()
            if discFamily != .cd, tone.levels == ToneProfile.fourLevels {
                throw DiscError.unsupported("\(discFamily.displayNameZH) 只支持两阶灰阶，CD 才能用四阶。")
            }
        }
        for layer in layers {
            guard !layer.id.isEmpty else {
                throw DiscError.invalidGeometry("图层 id 不能为空。")
            }
            guard layers.filter({ $0.id == layer.id }).count == 1 else {
                throw DiscError.invalidGeometry("图层 id「\(layer.id)」重复。")
            }
            guard !layer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DiscError.invalidGeometry("图层「\(layer.name)」的 name 不能为空。")
            }
            guard !layer.imagePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DiscError.invalidGeometry("图层「\(layer.name)」的 imagePath 不能为空。")
            }
            guard layer.translateXMm.isFinite, layer.translateYMm.isFinite, layer.rotationDeg.isFinite else {
                throw DiscError.invalidGeometry("图层「\(layer.name)」的位移/旋转必须是有限数值。")
            }
            guard layer.scale.isFinite, layer.scale > 0 else {
                throw DiscError.invalidGeometry("图层「\(layer.name)」的 scale 必须大于 0。")
            }
        }
        if !outputs.outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 输出路径只要求有目录部分；具体目录在导出时创建。
            guard URL(fileURLWithPath: outputs.outputPath).path.hasPrefix("/") else {
                throw DiscError.invalidGeometry("输出路径必须是绝对路径。")
            }
        }
        if let thumbnailPngBase64 {
            guard !thumbnailPngBase64.isEmpty,
                  thumbnailPngBase64.count <= Self.maxThumbnailBase64Length else {
                throw DiscError.invalidGeometry("thumbnailPngBase64 长度超出允许范围。")
            }
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, name, discFamily, geometry, layers, outputs
        case calibrationSessionPath, thumbnailPngBase64, createdUtc, modifiedUtc
        case tone, bluRay
    }

    /// 旧工程的 geometry 没有 `family`（源项目把它放在工程根上）。
    private struct GeometryPayload: Decodable {
        var family: DiscFamily?
        var innerRadiusMm: Double
        var outerRadiusMm: Double
        var sectors: Int
        var linearVelocityMmPerSecond: Double?
        var channelBitLengthNm: Double?
        var pitchLinear: Double?
        var pitchQuadratic: Double?
        var pitchCubic: Double?
        var invertMapping: Bool?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // discFamily 先读：它决定 geometry 与缺省值的介质分支。
        if let family = try? container.decode(DiscFamily.self, forKey: .discFamily) {
            discFamily = family
        } else {
            let token = try container.decode(String.self, forKey: .discFamily)
            guard let family = DiscFamily.fromProjectToken(token) else {
                throw DiscError.invalidGeometry("discFamily「\(token)」无效；仅支持 cd / dvd / bd。")
            }
            discFamily = family
        }

        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "未命名工程"

        let payload = try container.decode(GeometryPayload.self, forKey: .geometry)
        geometry = DiscGeometry(
            family: payload.family ?? discFamily,
            innerRadiusMm: payload.innerRadiusMm,
            outerRadiusMm: payload.outerRadiusMm,
            sectors: payload.sectors,
            linearVelocityMmPerSecond: payload.linearVelocityMmPerSecond ?? 1200,
            channelBitLengthNm: payload.channelBitLengthNm
                ?? (discFamily == .bluRay ? DiscGeometry.bluRayChannelBitLengthNm : 133.3),
            pitchLinear: payload.pitchLinear ?? 0,
            pitchQuadratic: payload.pitchQuadratic ?? 0,
            pitchCubic: payload.pitchCubic ?? 0,
            invertMapping: payload.invertMapping ?? false
        )

        layers = try container.decodeIfPresent([DesignLayer].self, forKey: .layers) ?? []
        outputs = try container.decodeIfPresent(ProjectOutputs.self, forKey: .outputs) ?? ProjectOutputs()
        calibrationSessionPath = try container.decodeIfPresent(String.self, forKey: .calibrationSessionPath)
        thumbnailPngBase64 = try container.decodeIfPresent(String.self, forKey: .thumbnailPngBase64)
        createdUtc = try container.decodeIfPresent(Date.self, forKey: .createdUtc) ?? Date()
        modifiedUtc = try container.decodeIfPresent(Date.self, forKey: .modifiedUtc) ?? createdUtc
        tone = try container.decodeIfPresent(ToneProfile.self, forKey: .tone)
        bluRay = try container.decodeIfPresent(BluRaySettings.self, forKey: .bluRay)

        if outputs.outputPath.isEmpty {
            outputs.outputPath = Self.defaultOutputPath(for: name, family: discFamily)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(name, forKey: .name)
        try container.encode(discFamily, forKey: .discFamily)
        try container.encode(geometry, forKey: .geometry)
        try container.encode(layers, forKey: .layers)
        try container.encode(outputs, forKey: .outputs)
        try container.encodeIfPresent(calibrationSessionPath, forKey: .calibrationSessionPath)
        try container.encodeIfPresent(thumbnailPngBase64, forKey: .thumbnailPngBase64)
        try container.encode(createdUtc, forKey: .createdUtc)
        try container.encode(modifiedUtc, forKey: .modifiedUtc)
        try container.encodeIfPresent(tone, forKey: .tone)
        try container.encodeIfPresent(bluRay, forKey: .bluRay)
    }

    // MARK: - 工厂

    /// 新建工程：按预设填几何，输出路径落在默认工程目录，影调取摄影起点。
    public static func makeNew(
        name: String,
        preset: DiscPreset,
        projectsDirectory: URL = ProjectStore.defaultProjectsDirectory,
        now: Date = Date()
    ) -> DiscProject {
        let family = preset.family
        let format: GenerationOutputFormat = family == .cd ? .wav : .iso
        let outputPath = projectsDirectory
            .appendingPathComponent(ProjectNaming.sanitizedFileStem(name))
            .appendingPathExtension(format.fileExtension)
            .path
        return DiscProject(
            name: name,
            discFamily: family,
            geometry: preset.geometry(),
            layers: [],
            outputs: ProjectOutputs(outputPath: outputPath, writeCue: true),
            calibrationSessionPath: nil,
            thumbnailPngBase64: nil,
            createdUtc: now,
            modifiedUtc: now,
            tone: .default,
            bluRay: family == .bluRay ? BluRaySettings(invertMapping: preset.invertMapping ?? false) : nil
        )
    }

    /// 改造/新建时的默认输出路径。
    public static func defaultOutputPath(for name: String, family: DiscFamily) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = trimmed.isEmpty ? "未命名工程" : trimmed
        let format: GenerationOutputFormat = family == .cd ? .wav : .iso
        return ProjectStore.defaultProjectsDirectory
            .appendingPathComponent(stem)
            .appendingPathExtension(format.fileExtension)
            .path
    }
}
