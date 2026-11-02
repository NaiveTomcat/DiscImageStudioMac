import Foundation

/// 标定用的二维点。单位由上下文决定：
/// - 盘面坐标：毫米，原点在盘心，**x 向右、y 向下**；
/// - 照片坐标：像素，原点在照片左上角（字段名沿用上游 `CalibrationPoint` 的
///   `X/Y`，这里翻成 Swift 风格的 `xMm/yMm`；用作照片点时不看名字只看数值）。
public struct CalibrationPoint: Codable, Equatable, Sendable {
    public var xMm: Double
    public var yMm: Double

    public init(xMm: Double, yMm: Double) {
        self.xMm = xMm
        self.yMm = yMm
    }

    /// 到盘心（或照片原点）的距离。
    public var radiusMm: Double {
        (xMm * xMm + yMm * yMm).squareRoot()
    }

    /// 相对盘心的角度（弧度，+x 轴起、逆时针为正；因为 y 向下，视觉上是顺时针为正）。
    public var angleRadians: Double {
        atan2(yMm, xMm)
    }

    public static let zero = CalibrationPoint(xMm: 0, yMm: 0)

    public func distance(to other: CalibrationPoint) -> Double {
        let dx = xMm - other.xMm
        let dy = yMm - other.yMm
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// 实拍照片里那张实体盘的规格。只用来恢复照片尺度，**不改变**已保存的图案生成映射。
public enum CalibrationDiscSize: String, Codable, CaseIterable, Sendable, Identifiable {
    /// 标准 12 cm 盘：实体外缘半径 60 mm。
    case standard12cm
    /// 8 cm 小盘：实体外缘半径 40 mm。
    case mini8cm

    public var id: String { rawValue }

    /// 实体外缘半径（mm）。
    public var physicalOuterRadiusMm: Double {
        switch self {
        case .standard12cm: return 60
        case .mini8cm: return 40
        }
    }

    /// 标准中心孔半径（mm）。CD/DVD/BD 的贯通孔径都是 15 mm。
    public var physicalHoleRadiusMm: Double { 7.5 }

    public var displayNameZH: String {
        switch self {
        case .standard12cm: return "标准 12 cm 光盘"
        case .mini8cm: return "8 cm 小盘"
        }
    }

    public static func fromPhysicalOuterRadiusMm(_ radius: Double) -> CalibrationDiscSize? {
        if abs(radius - 60) < 0.5 { return .standard12cm }
        if abs(radius - 40) < 0.5 { return .mini8cm }
        return nil
    }
}

/// 创建标定盘那一刻的生成参数快照。
///
/// 一张标定盘只对应一份快照；主页面后续改参不会改变已有记录的含义。
public struct CalibrationGenerationSnapshot: Codable, Equatable, Sendable {
    /// 当前标定图案 schema；上游 schema 6。旧版梳形图案不迁移。
    public static let currentSchemaVersion = 6

    public var schemaVersion: Int
    public var geometry: DiscGeometry
    public var tone: ToneProfile
    /// BD 的绘图起始扇区（含）；0 表示从数据区起点。
    public var drawingStartSector: Int
    /// BD 的绘图结束扇区（不含）；0 表示到数据区终点。
    public var drawingEndSectorExclusive: Int
    /// CD 生成时的交织开关（快照的一部分，DVD/BD 固定 true）。
    public var cdInterleave: Bool
    public var generatedUtc: Date

    public init(
        geometry: DiscGeometry,
        tone: ToneProfile = .default,
        drawingStartSector: Int = 0,
        drawingEndSectorExclusive: Int = 0,
        cdInterleave: Bool = true,
        generatedUtc: Date = Date()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.geometry = geometry
        self.tone = tone
        self.drawingStartSector = drawingStartSector
        self.drawingEndSectorExclusive = drawingEndSectorExclusive
        self.cdInterleave = cdInterleave
        // JSON 用 ISO 8601（秒精度）保存，这里先截到秒，保证往返完全相等。
        self.generatedUtc = Date(timeIntervalSince1970: generatedUtc.timeIntervalSince1970.rounded())
    }

    /// 图案按生成外半径缩放，所以「图案比例」就是它（mm）。
    public var patternScaleMm: Double { geometry.outerRadiusMm }

    /// 原图 1 像素对应的毫米数（与普通图片编码器同一坐标映射）。
    public var patternMillimetresPerPixel: Double {
        CalibrationPattern.millimetresPerPixel(
            outerRadiusMm: geometry.outerRadiusMm,
            family: geometry.family
        )
    }

    /// 内半径以内的环带被裁掉；BD 还要按绘图扇区范围裁。
    public var drawingInnerRadiusMm: Double {
        parameters.drawingInnerRadiusMm
    }

    public var drawingOuterRadiusMm: Double {
        parameters.drawingOuterRadiusMm
    }

    private var parameters: CalibrationParameters {
        CalibrationParameters(
            geometry: geometry,
            drawingStartSector: drawingStartSector,
            drawingEndSectorExclusive: drawingEndSectorExclusive
        )
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DiscError.invalidGeometry("不支持的标定图案版本 \(schemaVersion)，请重新创建标定图案。")
        }
        try geometry.validate()
        let parameters = CalibrationParameters(
            geometry: geometry,
            drawingStartSector: drawingStartSector,
            drawingEndSectorExclusive: drawingEndSectorExclusive
        )
        try parameters.validate()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, geometry, tone, drawingStartSector, drawingEndSectorExclusive
        case cdInterleave, generatedUtc
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        geometry = try container.decode(DiscGeometry.self, forKey: .geometry)
        tone = try container.decodeIfPresent(ToneProfile.self, forKey: .tone) ?? .default
        drawingStartSector = try container.decodeIfPresent(Int.self, forKey: .drawingStartSector) ?? 0
        drawingEndSectorExclusive = try container.decodeIfPresent(Int.self, forKey: .drawingEndSectorExclusive) ?? 0
        cdInterleave = try container.decodeIfPresent(Bool.self, forKey: .cdInterleave) ?? true
        generatedUtc = try container.decodeIfPresent(Date.self, forKey: .generatedUtc) ?? Date(timeIntervalSince1970: 0)
    }
}

/// 一条沿径向曲线、从内到外排列的描点序列。
///
/// 当前界面只允许一条曲线（`armIndex == 0`），整体转角由拟合自由处理，
/// 所以不需要用户辨认是哪一条十字臂。
public struct CalibrationCrossTrace: Codable, Equatable, Sendable {
    public var armIndex: Int
    public var points: [CalibrationPoint]

    public init(armIndex: Int = 0, points: [CalibrationPoint] = []) {
        self.armIndex = armIndex
        self.points = points
    }
}

/// 照片矫正这一步保留下来的全部输入。
///
/// 缩小的原照片直接内嵌（base64 PNG），记录**不依赖**原照片路径。
public struct CalibrationPhotoSession: Codable, Equatable, Sendable {
    /// 允许内嵌的最大 base64 长度（与上游一致，约 10 MB 原图）。
    public static let maximumImageBase64Length = 14_000_000
    /// 交互用照片缩放到的最长边。
    public static let maximumImageDimension = 1600

    public var imagePngBase64: String
    /// 实体外缘控制点（照片像素坐标）。
    public var outerBoundary: [CalibrationPoint]
    /// 中心孔边缘控制点（照片像素坐标）。
    public var holeBoundary: [CalibrationPoint]
    /// 所选实体盘片的外缘半径（60 或 40 mm）。
    public var physicalOuterRadiusMm: Double
    /// 矫正是否已确认；未确认时不允许保存描线点。
    public var rectificationConfirmed: Bool
    /// 曲线描点（盘面毫米坐标，从内到外）。当前最多一条。
    public var traces: [CalibrationCrossTrace]

    public init(
        imagePngBase64: String,
        outerBoundary: [CalibrationPoint] = [],
        holeBoundary: [CalibrationPoint] = [],
        physicalOuterRadiusMm: Double = 60,
        rectificationConfirmed: Bool = false,
        traces: [CalibrationCrossTrace] = []
    ) {
        self.imagePngBase64 = imagePngBase64
        self.outerBoundary = outerBoundary
        self.holeBoundary = holeBoundary
        self.physicalOuterRadiusMm = physicalOuterRadiusMm
        self.rectificationConfirmed = rectificationConfirmed
        self.traces = traces
    }

    /// 由一张已导入的照片创建记录：自动缩到交互尺寸并编码成 PNG。
    public init(
        image: RasterImage,
        outerBoundary: [CalibrationPoint] = [],
        holeBoundary: [CalibrationPoint] = [],
        discSize: CalibrationDiscSize = .standard12cm,
        rectificationConfirmed: Bool = false,
        traces: [CalibrationCrossTrace] = []
    ) throws {
        let scaled = image.scaled(maxDimension: Self.maximumImageDimension)
        let png = try scaled.pngData()
        self.init(
            imagePngBase64: png.base64EncodedString(),
            outerBoundary: outerBoundary,
            holeBoundary: holeBoundary,
            physicalOuterRadiusMm: discSize.physicalOuterRadiusMm,
            rectificationConfirmed: rectificationConfirmed,
            traces: traces
        )
    }

    public var discSize: CalibrationDiscSize? {
        CalibrationDiscSize.fromPhysicalOuterRadiusMm(physicalOuterRadiusMm)
    }

    /// 解码内嵌照片。失败即说明记录已损坏。
    public func decodedImage() throws -> RasterImage {
        guard let data = Data(base64Encoded: imagePngBase64), !data.isEmpty else {
            throw DiscError.io("标定照片不是有效的 base64 PNG 数据")
        }
        return try RasterImage.load(data: data)
    }

    public func validate() throws {
        guard !imagePngBase64.isEmpty,
              imagePngBase64.count <= Self.maximumImageBase64Length else {
            throw DiscError.invalidGeometry("标定照片为空或过大，请重新导入照片。")
        }
        guard discSize != nil else {
            throw DiscError.invalidGeometry("请选择 12 cm 或 8 cm 光盘。")
        }
        try Self.validateBoundary(outerBoundary)
        try Self.validateBoundary(holeBoundary)
        guard traces.count <= 1 else {
            throw DiscError.invalidGeometry("当前只支持沿一条径向曲线标定。")
        }
        for trace in traces {
            guard trace.armIndex == 0 else {
                throw DiscError.invalidGeometry("十字线记录无效。")
            }
            guard trace.points.count <= 4000 else {
                throw DiscError.invalidGeometry("曲线点过多，请清理后重试。")
            }
            for point in trace.points {
                guard point.xMm.isFinite, point.yMm.isFinite,
                      point.radiusMm <= physicalOuterRadiusMm else {
                    throw DiscError.invalidGeometry("十字线记录中有超出盘面的点。")
                }
            }
        }
        if !rectificationConfirmed, traces.contains(where: { !$0.points.isEmpty }) {
            throw DiscError.invalidGeometry("尚未确认照片矫正，不能保存描线点。")
        }
    }

    private static func validateBoundary(_ points: [CalibrationPoint]) throws {
        guard points.count >= 5, points.count <= 128 else {
            throw DiscError.invalidGeometry("照片轮廓控制点数量应在 5–128 之间。")
        }
        for point in points {
            guard point.xMm.isFinite, point.yMm.isFinite,
                  point.xMm >= 0, point.yMm >= 0,
                  point.xMm <= 2000, point.yMm <= 2000 else {
                throw DiscError.invalidGeometry("照片轮廓控制点无效。")
            }
        }
    }
}

/// 一次标定的完整记录（schema 6）。
public struct CalibrationSession: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 6

    public var schemaVersion: Int
    public var generation: CalibrationGenerationSnapshot
    public var photo: CalibrationPhotoSession?
    public var fitOptions: CalibrationFitOptions?

    public init(
        generation: CalibrationGenerationSnapshot,
        photo: CalibrationPhotoSession? = nil,
        fitOptions: CalibrationFitOptions? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.generation = generation
        self.photo = photo
        self.fitOptions = fitOptions
    }

    /// 当前曲线（最多一条）。
    public var trace: CalibrationCrossTrace? {
        photo?.traces.first
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DiscError.invalidGeometry("不支持的标定会话版本 \(schemaVersion)。")
        }
        try generation.validate()
        try photo?.validate()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generation, photo, fitOptions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        generation = try container.decode(CalibrationGenerationSnapshot.self, forKey: .generation)
        photo = try container.decodeIfPresent(CalibrationPhotoSession.self, forKey: .photo)
        fitOptions = try container.decodeIfPresent(CalibrationFitOptions.self, forKey: .fitOptions)
    }
}

/// 单条曲线反推的搜索选项。
public struct CalibrationFitOptions: Codable, Equatable, Sendable {
    /// 初始搜索半径范围（±mm）。默认 ±0.02。
    public var searchRangeMm: Double
    /// Huber 尺度（mm）：超过它的点按线性降权。
    public var huberDeltaMm: Double
    /// 候选上限。
    public var maxCandidates: Int
    /// 是否同时拟合 DVD 三次轨距系数。
    public var fitDvdPitch: Bool
    /// 轨距系数搜索范围（±）。
    public var pitchCoefficientRange: Double
    /// 最优解落在搜索边界时自动扩大范围（±0.02 → ±0.1 → ±0.5）。
    public var autoRange: Bool
    /// 按观测尺度自适应收紧 Huber 尺度（挡住少量误点的杠杆）。
    public var adaptiveRobustScale: Bool

    public init(
        searchRangeMm: Double = 0.02,
        huberDeltaMm: Double = 0.8,
        maxCandidates: Int = 8,
        fitDvdPitch: Bool = true,
        pitchCoefficientRange: Double = 0.05,
        autoRange: Bool = true,
        adaptiveRobustScale: Bool = false
    ) {
        self.searchRangeMm = searchRangeMm
        self.huberDeltaMm = huberDeltaMm
        self.maxCandidates = maxCandidates
        self.fitDvdPitch = fitDvdPitch
        self.pitchCoefficientRange = pitchCoefficientRange
        self.autoRange = autoRange
        self.adaptiveRobustScale = adaptiveRobustScale
    }

    public static let `default` = CalibrationFitOptions()

    /// 自动扩大的范围序列（第一个是初始值）。
    public static let autoRangeSteps: [Double] = [0.02, 0.1, 0.5]

    public func validate() throws {
        guard searchRangeMm.isFinite, searchRangeMm > 0, searchRangeMm <= 5 else {
            throw DiscError.invalidGeometry("搜索半径范围应在 0–5 mm 内。")
        }
        guard huberDeltaMm.isFinite, huberDeltaMm > 0, huberDeltaMm <= 10 else {
            throw DiscError.invalidGeometry("控制点容差应在 0–10 mm 内。")
        }
        guard maxCandidates >= 1, maxCandidates <= 20 else {
            throw DiscError.invalidGeometry("候选数量应在 1–20 之间。")
        }
        guard pitchCoefficientRange.isFinite, pitchCoefficientRange > 0,
              pitchCoefficientRange <= 10 else {
            throw DiscError.invalidGeometry("轨距系数搜索范围应在 0–10 内。")
        }
    }
}

/// 一个反推候选：内外半径、整体转角、三次轨距系数与残差统计。
public struct CalibrationFitCandidate: Sendable, Equatable {
    public var innerRadiusMm: Double
    public var outerRadiusMm: Double
    /// 整体转角（弧度，已归一化到 (−π, π]）。不写入刻录起始角。
    public var rotationRadians: Double
    public var pitchLinear: Double
    public var pitchQuadratic: Double
    public var pitchCubic: Double
    /// 局部法向残差的均方根（mm）——不是端点对应误差。
    public var rmsErrorMm: Double
    /// 单点最大残差（mm）。
    public var maxErrorMm: Double
    /// 超过三倍 Huber 尺度的点数。
    public var outlierCount: Int
    /// Huber 代价（越小越好，仅用于候选排序）。
    public var robustCost: Double

    /// 平均偏差超过此值（mm）的候选不能应用。
    public static let applicableRmsErrorMm = 0.35
    /// 最大偏差超过此值（mm）的候选不能应用。
    public static let applicableMaxErrorMm = 0.8

    public init(
        innerRadiusMm: Double,
        outerRadiusMm: Double,
        rotationRadians: Double,
        pitchLinear: Double = 0,
        pitchQuadratic: Double = 0,
        pitchCubic: Double = 0,
        rmsErrorMm: Double = .nan,
        maxErrorMm: Double = .nan,
        outlierCount: Int = 0,
        robustCost: Double = .nan
    ) {
        self.innerRadiusMm = innerRadiusMm
        self.outerRadiusMm = outerRadiusMm
        self.rotationRadians = rotationRadians
        self.pitchLinear = pitchLinear
        self.pitchQuadratic = pitchQuadratic
        self.pitchCubic = pitchCubic
        self.rmsErrorMm = rmsErrorMm
        self.maxErrorMm = maxErrorMm
        self.outlierCount = outlierCount
        self.robustCost = robustCost
    }

    /// 是否满足「可应用」门槛（平均 ≤ 0.35 mm 且最大 ≤ 0.8 mm）。
    public var isApplicable: Bool {
        guard rmsErrorMm.isFinite, maxErrorMm.isFinite else { return false }
        return rmsErrorMm <= Self.applicableRmsErrorMm && maxErrorMm <= Self.applicableMaxErrorMm
    }

    public var hasCubicPitch: Bool {
        pitchLinear != 0 || pitchQuadratic != 0 || pitchCubic != 0
    }

    /// 把候选写回一份几何：只更新内外半径与三次轨距系数，其余保持不变
    /// （BD 的极性/总扇数由生成快照决定，不在这里改）。
    public func applying(to base: DiscGeometry) -> DiscGeometry {
        var updated = base
        updated.innerRadiusMm = innerRadiusMm
        updated.outerRadiusMm = outerRadiusMm
        if base.family == .dvd {
            updated.pitchLinear = pitchLinear
            updated.pitchQuadratic = pitchQuadratic
            updated.pitchCubic = pitchCubic
        }
        return updated
    }
}

/// 单条曲线反推的结果。
public struct CalibrationFitResult: Sendable, Equatable {
    /// 是否得到可用候选（不代表点数足够唯一）。
    public var succeeded: Bool
    public var candidates: [CalibrationFitCandidate]
    /// 最优候选；失败时为 nil。
    public var best: CalibrationFitCandidate?
    /// 面向用户的提示（补点、偏差过大、范围扩大等）。
    public var warnings: [String]
    /// 最终使用的搜索范围 `(−range, +range)`（mm）；未搜索时为 nil。
    public var searchRangeMm: (Double, Double)?
    /// 最优解是否贴住搜索边界（说明范围可能截断了真实参数）。
    public var boundaryLimited: Bool

    public init(
        succeeded: Bool,
        candidates: [CalibrationFitCandidate] = [],
        best: CalibrationFitCandidate? = nil,
        warnings: [String] = [],
        searchRangeMm: (Double, Double)? = nil,
        boundaryLimited: Bool = false
    ) {
        self.succeeded = succeeded
        self.candidates = candidates
        self.best = best
        self.warnings = warnings
        self.searchRangeMm = searchRangeMm
        self.boundaryLimited = boundaryLimited
    }

    public static func failed(_ reasons: [String]) -> CalibrationFitResult {
        CalibrationFitResult(succeeded: false, warnings: reasons)
    }

    /// 最优候选的残差均方根；失败时为 NaN。
    public var rmsErrorMm: Double { best?.rmsErrorMm ?? .nan }

    /// 最优候选能否应用：必须成功，且平均/最大偏差都在门槛内。
    public var isApplicable: Bool { succeeded && (best?.isApplicable ?? false) }

    /// 不能应用时的原因（给 UI 状态行用）。
    public var rejectionReason: String? {
        guard succeeded else { return warnings.first }
        guard let best else { return "没有可用候选。" }
        if best.rmsErrorMm > CalibrationFitCandidate.applicableRmsErrorMm {
            return "平均偏差 \(Self.format(best.rmsErrorMm)) mm 超过 0.35 mm，请修正标红点或补点。"
        }
        if best.maxErrorMm > CalibrationFitCandidate.applicableMaxErrorMm {
            return "最大偏差 \(Self.format(best.maxErrorMm)) mm 超过 0.8 mm，请修正标红点或补点。"
        }
        return nil
    }

    /// 无警告即视为「低残差且无歧义」，可直接应用。
    public var isReliable: Bool { succeeded && warnings.isEmpty }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    public static func == (lhs: CalibrationFitResult, rhs: CalibrationFitResult) -> Bool {
        guard lhs.succeeded == rhs.succeeded,
              lhs.candidates == rhs.candidates,
              lhs.best == rhs.best,
              lhs.warnings == rhs.warnings,
              lhs.boundaryLimited == rhs.boundaryLimited else { return false }
        switch (lhs.searchRangeMm, rhs.searchRangeMm) {
        case (nil, nil): return true
        case let (lhsRange?, rhsRange?):
            return lhsRange.0 == rhsRange.0 && lhsRange.1 == rhsRange.1
        default: return false
        }
    }
}
