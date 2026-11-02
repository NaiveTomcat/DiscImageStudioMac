import Foundation

/// 内置盘片预设（与源项目 `built-in-disc-presets.json` 对齐）。
///
/// 用户自建预设走 `DiscPresetStore`（UI 层），这里是只读的出厂清单。
public struct DiscPreset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    public var detail: String
    public var family: DiscFamily
    public var innerRadiusMm: Double
    public var outerRadiusMm: Double
    public var sectors: Int
    /// CD：线速度 mm/s
    public var linearVelocityMmPerSecond: Double?
    /// DVD：通道位长 nm
    public var channelBitLengthNm: Double?
    /// DVD：三次轨距系数
    public var pitchLinear: Double?
    public var pitchQuadratic: Double?
    public var pitchCubic: Double?
    /// BD：映射极性反转
    public var invertMapping: Bool?
    /// 是否是实盘标定得到的参数（UI 上会标「实测」）
    public var isMeasured: Bool

    public init(
        id: String,
        displayName: String,
        detail: String,
        family: DiscFamily,
        innerRadiusMm: Double,
        outerRadiusMm: Double,
        sectors: Int,
        linearVelocityMmPerSecond: Double? = nil,
        channelBitLengthNm: Double? = nil,
        pitchLinear: Double? = nil,
        pitchQuadratic: Double? = nil,
        pitchCubic: Double? = nil,
        invertMapping: Bool? = nil,
        isMeasured: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
        self.family = family
        self.innerRadiusMm = innerRadiusMm
        self.outerRadiusMm = outerRadiusMm
        self.sectors = sectors
        self.linearVelocityMmPerSecond = linearVelocityMmPerSecond
        self.channelBitLengthNm = channelBitLengthNm
        self.pitchLinear = pitchLinear
        self.pitchQuadratic = pitchQuadratic
        self.pitchCubic = pitchCubic
        self.invertMapping = invertMapping
        self.isMeasured = isMeasured
    }

    /// 转成引擎使用的几何。
    public func geometry() -> DiscGeometry {
        DiscGeometry(
            family: family,
            innerRadiusMm: innerRadiusMm,
            outerRadiusMm: outerRadiusMm,
            sectors: sectors,
            linearVelocityMmPerSecond: linearVelocityMmPerSecond ?? 1200,
            channelBitLengthNm: channelBitLengthNm ?? DiscGeometry.bluRayChannelBitLengthNm,
            pitchLinear: pitchLinear ?? 0,
            pitchQuadratic: pitchQuadratic ?? 0,
            pitchCubic: pitchCubic ?? 0,
            invertMapping: invertMapping ?? false
        )
    }

    /// 反算螺距（mm），用于界面显示与自检。
    public var pitchMm: Double { geometry().spiral.pitchMm }

    /// 反算螺距（µm），源项目文档里用的单位。
    public var pitchMicrometres: Double { pitchMm * 1000 }

    // MARK: - 出厂清单

    public static let cd80 = DiscPreset(
        id: "cd-80",
        displayName: "标准 80min CD",
        detail: "ECMA-130／ISO/IEC 10149 标准速度 1200 mm/s；120 mm 盘、约 80 分钟，359,849 扇区（24.5–56.8 mm）。",
        family: .cd,
        innerRadiusMm: 24.5,
        outerRadiusMm: 56.8,
        sectors: 359_849,
        linearVelocityMmPerSecond: 1200
    )

    public static let cd74 = DiscPreset(
        id: "cd-74",
        displayName: "标准 74min CD",
        detail: "ECMA-130／ISO/IEC 10149 标准速度 1200 mm/s；120 mm 盘、约 74 分钟，333,000 扇区（24.5–56.8 mm）。",
        family: .cd,
        innerRadiusMm: 24.5,
        outerRadiusMm: 56.8,
        sectors: 333_000,
        linearVelocityMmPerSecond: 1200
    )

    public static let ritekMedicalAqua = DiscPreset(
        id: "ritek-medical-aqua",
        displayName: "铼德医疗水蓝盘（实测）",
        detail: "实测参数：内半径 24.911275 mm、外半径 57.931155 mm、359,845 扇区；扫描速度采用 1200 mm/s。",
        family: .cd,
        innerRadiusMm: 24.911_275,
        outerRadiusMm: 57.931_155,
        sectors: 359_845,
        linearVelocityMmPerSecond: 1200,
        isMeasured: true
    )

    public static let verbatimAzo43438 = DiscPreset(
        id: "verbatim-azo-43438",
        displayName: "Verbatim CD-R AZO (43438)（实测）",
        detail: "实测参数：内半径 24.837775 mm、外半径 58.020875 mm、359,848 扇区；扫描速度采用 1200 mm/s。",
        family: .cd,
        innerRadiusMm: 24.837_775,
        outerRadiusMm: 58.020_875,
        sectors: 359_848,
        linearVelocityMmPerSecond: 1200,
        isMeasured: true
    )

    public static let dvd5_120mm = DiscPreset(
        id: "dvd-5-120mm",
        displayName: "标准 12cm 单层 DVD",
        detail: "ISO/IEC 16448 标准单层 120 mm DVD（DVD-5）数据区：24–58 mm，共 2,295,104 个扇区。",
        family: .dvd,
        innerRadiusMm: 24.0,
        outerRadiusMm: 58.0,
        sectors: 2_295_104,
        channelBitLengthNm: 133.3
    )

    public static let dvd5_80mm = DiscPreset(
        id: "dvd-5-80mm",
        displayName: "标准 8cm 单层 DVD",
        detail: "ISO/IEC 16448 标准单层 80 mm DVD 数据区：24–38 mm，共 714,544 个扇区。",
        family: .dvd,
        innerRadiusMm: 24.0,
        outerRadiusMm: 38.0,
        sectors: 714_544,
        channelBitLengthNm: 133.3
    )

    public static let verbatimDvdAzo43533 = DiscPreset(
        id: "verbatim-dvd-r-azo-43533",
        displayName: "Verbatim DVD-R AZO (43533)（实测）",
        detail: "已验证标定参数：23.9914606277–57.9648936579 mm，共 2,297,888 个扇区；采用三次轨距分布。",
        family: .dvd,
        innerRadiusMm: 23.991_460_627_731_737,
        outerRadiusMm: 57.964_893_657_925_366,
        sectors: 2_297_888,
        channelBitLengthNm: 133.3,
        pitchLinear: -3.925_685_431_922_768_4e-05,
        pitchQuadratic: 6.964_795_915_429_256e-05,
        pitchCubic: -4.670_918_950_137_523e-05,
        isMeasured: true
    )

    public static let bdRsl25gb = DiscPreset(
        id: "bd-r-sl-25gb",
        displayName: "标准 25GB 单层 BD",
        detail: "ISO/IEC 30190 标准单层 BD-R 数据区：24–58 mm，共 12,219,392 个扇区。",
        family: .bluRay,
        innerRadiusMm: 24.0,
        outerRadiusMm: 58.0,
        sectors: 12_219_392,
        invertMapping: false
    )

    public static let bdRitek10x = DiscPreset(
        id: "bd-r-ritek-10x",
        displayName: "铼德 BD-R 10x（实测）",
        detail: "实测参数：内半径 23.988221 mm、外半径 58.023235 mm、12,219,392 扇区。",
        family: .bluRay,
        innerRadiusMm: 23.988_221_056_165_62,
        outerRadiusMm: 58.023_234_731_100_764,
        sectors: 12_219_392,
        invertMapping: false,
        isMeasured: true
    )

    public static let bdVerbatim64099 = DiscPreset(
        id: "bd-r-verbatim-64099",
        displayName: "Verbatim BD-R (64099)（实测）",
        detail: "实测参数：内半径 23.987042 mm、外半径 57.987960 mm、12,219,392 扇区。",
        family: .bluRay,
        innerRadiusMm: 23.987_042_157_339_335,
        outerRadiusMm: 57.987_960_341_783_236,
        sectors: 12_219_392,
        invertMapping: false,
        isMeasured: true
    )

    /// 全部出厂预设。
    public static let builtIn: [DiscPreset] = [
        cd80, cd74, ritekMedicalAqua, verbatimAzo43438,
        dvd5_120mm, dvd5_80mm, verbatimDvdAzo43533,
        bdRsl25gb, bdRitek10x, bdVerbatim64099,
    ]

    public static func presets(for family: DiscFamily) -> [DiscPreset] {
        builtIn.filter { $0.family == family }
    }

    /// 每种介质的默认预设。
    public static func defaultPreset(for family: DiscFamily) -> DiscPreset {
        switch family {
        case .cd: return cd80
        case .dvd: return dvd5_120mm
        case .bluRay: return bdRsl25gb
        }
    }

    public static func preset(id: String) -> DiscPreset? {
        builtIn.first { $0.id == id }
    }

    /// CD 的绘图外半径（源项目默认 57.5 mm，允许图案略超出数据区）。
    public static func projectionRadius(for family: DiscFamily) -> Double {
        switch family {
        case .cd: return 57.5
        case .dvd: return 58.0
        case .bluRay: return 58.0
        }
    }
}
