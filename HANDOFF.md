# HANDOFF — DiscImageStudioMac

> 写给在 `~/CodingProjects/DiscImageStudioMac` 新开的 DSH 工作区 session。
> 假设你**没有**上一个 session 的任何上下文：这份文档就是全部上下文。
> 源仓库（只读参考）：`~/CodingProjects/DiscImageStudio`（Windows / C# / .NET 10，约 6 万行）。

---

## 0. 一句话任务

把 Windows 上的 **Disc Image Studio**（把图片编码进 CD / DVD / 蓝光**盘面物理层**，刻录后肉眼可见）移植成 **macOS 原生 SwiftUI 应用**：三介质图像编码引擎 + 五工作区 GUI + 基于 `drutil`/`hdiutil` 的刻录封装 + 可跑通的回归测试。

**用户已拍板的三个决策**（不要再问）：

1. 仓库位置：`~/CodingProjects/DiscImageStudioMac`（本目录，独立 git 仓库，已 `git init`）
2. 首版范围：**一次到位三介质 + 全 GUI（含蓝光）**
3. 刻录方式：**`drutil` / `hdiutil` 命令行封装**（不要上 IOKit / 裸 SCSI）

---

## 1. 源仓库速写

| 事实 | 值 |
|---|---|
| 语言/框架 | C# 13 / .NET 10 / WPF，Windows 10 2004+ |
| 规模 | 约 60,781 行 C#，11 个项目，49 次提交 |
| 版本 | 1.3.3，GPL-3.0-or-later，CD 交织代码移植自 arduinocelentano/cdimage |
| 参考标准 | ECMA-130（CD）、ECMA-267（DVD-ROM）、ECMA-359（DVD-R）、ISO/IEC 30190（BD-R）|

**三介质成熟度（重要，决定移植优先级）**：

| | DVD | CD | 蓝光 |
|---|---|---|---|
| 成熟度 | ★★★★★ 主力 | ★★★☆☆ 可用有疑点 | ★★☆☆☆ 实验性 |
| 编码链 | ECC/EFMPlus/NRZI **全实现** | **只有字节级延迟重排，无 CIRC、无 EFM** | 17PP/ECC/LDC-BIS/UDF **全实现** |
| 生成算法 | 约束求解（beam search）**或**快速纹理映射 | 直接查表映射 | 直接字节选值 |
| 实盘证据 | 有标定前后**实拍对比**；极性按实盘结果反转过 | 仅一次"无重影"反馈 | 无 |

**原生项目里 GUI 走的是"快速纹理映射"路径**（`solve` 命令），不是 beam search 求解器 —— 所以**首版不必移植求解器**，这砍掉了最大的一块工作量。

---

## 2. 可以直接照抄的编码规格

### 2.1 完整链路（每步都有源文件可查）

**DVD**（源：`src/DvdImageSolver/`）

```
图片 → 按 619008 通道位坐标系采样 → 每 16-bit 码字取 land 数目标
     → 只在 payload 字节上选 0xA5/0x92（扰码域）
     → P = Q XOR 扰码   → 重建 ECC（PI/PO）→ EFMPlus → NRZI
```

- 每扇区 2048 字节 payload；16 扇区 = 1 ECC Block = 619008 通道位
- 每扇区 38688 通道位 = 13 × 2 × (32 + 1456)
- Sync Frame：91 字节 / 1488 bit，26 帧/扇区，416 帧/Block
- ECC 208×182，其中数据 192×172；PI 208 行零余数，PO 172 列零余数
- PO 行交织：第 row 行铺到 `13*(row-191)-1`
- EFMPlus：每 91 字节 Sync Frame 并行维护 Stream1/Stream2，取 `|DSV|` 小者（相等取 Stream1）；`|DSV| > 63` 时尝试替换 SYNC 主/副码
- NRZI：transition=1 翻转电平；`land=1=白`，`pit=0=黑`
- 灰阶字节：**黑 = 扰码域 `0xA5`（5 次 transition），白 = `0x92`（2 次）**；旧镜像回读识别 `0x66`→0、`0xB9`→85
- 固定约定：Sector Information `0x00`、DVD-R Data Frame 的 RSV 为六个 `0x00`、`PSN = 0x30000 + LBA`

**CD**（源：`src/DiscImageStudio.Cd/`）

```
图片 → (r, θ) → globalByte index → 灰阶映射 0x0D/0xAA → 112 帧环形延迟交织 → 2352 字节扇区 → WAV/RAW
```

- 2352 字节/扇区，75 扇区/秒，24 字节/帧
- 几何：`r = sqrt(ri² + f(ro²-ri²))`，`θ = 2vT/(ro²-ri²)·(r-ri)`
- 采样：图心对盘心，`pixelRadius = (size/2) · r / ImageOuterRadiusMm`（CD 默认 57.5 mm）
- 灰阶：`gray < 128 → 0x0D`，否则 `0xAA`；四阶为 `0x0D / 0x10 / 0x63 / 0xAA`
- 延迟交织：24 字节/帧、112 帧环形延迟线，逻辑字节 i 落到文件 `i + offset(i % 24)`，offset 落在 **72…2592 字节**；尾部会丢 **1318–1332 字节**
- 输出：WAV = 44 字节 RIFF 头 + **小端** PCM（44.1 kHz / 16 bit / 双声道）+ 同名 `.cue`（`FILE ... WAVE`）；RAW = **大端**
- ⚠️ 生成链路**没有** CIRC 校验和 EFM 调制，只做字节重排。别去移植 CIRC。

**蓝光**（源：`src/DiscImageStudio.BluRay/`）

```
图片 → 源图分辨率二值化（128 阈值）→ 每个 payload 字节按 LDC 交织算物理位置
     → 暗 0xAA（偏 3T）/ 亮 0x44（偏 6T），可反转 → XOR 扰码 → EDC → LDC/BIS → 17PP → NRZI → RUB
```

- 2048 + 4 字节 EDC；LDC = RS(248,216) × 304 码字；BIS = RS(9,5) + RS(62,30)
- 17PP 为 RLL(1,7)；28 个 DC 控制位贪心选择；NRZI 后加 run-in/run-out
- **32 扇区 = 1 簇 = 1 recording unit**，962,136 通道位；单层 12,219,392 扇区；位长 74.5 nm，轨距 0.320 µm
- 32 扇区对齐的算术原因：`32 × 2052 = 65,664 = 304 × 216`，正好铺满 LDC 的 304 码字 × 216 数据字节
- 3T/6T 定灰的出处：整簇统计 `AA` 的 3T = 265,136、`44` 的 6T = 116,575（各为 256 个重复字节之首）—— 是**数字编码结果，不是实测光学极性**
- ISO 旁写 sidecar `bd-r-image-v1` JSON：扇区、半径、绘图起止、极性、影调、UDF 时间戳
- UDF 2.01，最小 640 扇区且必须 %32；单文件 > 4 GiB 用 64 位 extent，按 `0x3ffff800` 拆分

### 2.2 几何与公式（已复算验证）

```
CD  : L = (N / 75) * v                       [mm]
DVD : L = N * 38688 * bitLengthNm * 1e-6     [mm]
BD  : L = (N / 32) * 962136 * 74.5e-6        [mm]

螺距 pitch = π(ro² - ri²) / L
累计圈数 turns = (ro - ri) / pitch
相位 turns(r) = turns * (r² - ri²) / (ro² - ri²)
```

自检对照（可用于单元测试断言）：

| 参数 | 反算螺距 | 期望 |
|---|---|---|
| CD 80min：359,849 扇区 / 24.5–56.8 mm / 1200 mm/s | **1.4329 µm** | ⚠️ 超出 ECMA-130 的 1.5–1.7 µm（源项目已知缺陷） |
| DVD 默认：2,295,104 扇区 / 24–58 mm / 133.3 nm | **0.7398 µm** | ≈ 0.74 µm ✅ |

### 2.3 内置盘片预设（直接抄进代码）

| id | 形态 | 内/外半径 mm | 扇区 | 其他 |
|---|---|---|---|---|
| `cd-80` | CD | 24.5 / 56.8 | 359,849 | 1200 mm/s |
| `cd-74` | CD | 24.5 / 56.8 | 333,000 | 1200 mm/s |
| `ritek-medical-aqua` | CD | 24.911275 / 57.931155 | 359,845 | 实测 |
| `verbatim-azo-43438` | CD | 24.837775 / 58.020875 | 359,848 | 实测 |
| `dvd-5-120mm` | DVD | 24 / 58 | 2,295,104 | 133.3 nm |
| `dvd-5-80mm` | DVD | 24 / 38 | 714,544 | 133.3 nm |
| `verbatim-dvd-r-azo-43533` | DVD | 23.991460627731737 / 57.964893657925366 | 2,297,888 | 三次轨距 `-3.9256854319227684e-05 / 6.964795915429256e-05 / -4.670918950137523e-05` |
| `bd-r-sl-25gb` | BD | 24 / 58 | 12,219,392 | `invertMapping=false` |
| `bd-r-ritek-10x` | BD | 23.98822105616562 / 58.023234731100764 | 12,219,392 | 实测 |
| `bd-r-verbatim-64099` | BD | 23.987042157339335 / 57.987960341783236 | 12,219,392 | 实测 |

### 2.4 EFMPlus 表从哪来（关键）

DVD 的 256×4 状态转换表**不要手抄**。源仓库里的表是脚本从标准 PDF 生成的：

- 生成脚本：`tools/generate_efm_tables.py`（依赖 `pdfplumber`，从 ECMA-267 Annex G 第 67–74 页提取）
- 已生成的 C# 表：`src/DvdImageSolver/Encoding/EfmPlusTables.cs`
- **最省事的做法：写个一次性脚本，把 `EfmPlusTables.cs` 里的常量数组机械转成 Swift**（正则替换 + 格式化成 Swift 数组字面量）。不要凭记忆重建，也不要从网上找表。

---

## 3. macOS 移植的边界

### 3.1 能原样搬的

全部编码算法都是纯计算（字节进、字节出），与操作系统无关：ECC、EFMPlus、17PP、LDC/BIS、扰码、交织、ISO9660、UDF、螺旋几何。

### 3.2 不能搬的

| Windows | macOS 替代 |
|---|---|
| IMAPI2（`IDiscFormat2Data`、`ICdRawSession`、MMC 直写） | `drutil` / `hdiutil` 命令行 |
| WPF | SwiftUI |
| System.Drawing / WPF 位图 | CoreGraphics / ImageIO |

**刻录用到的命令**（都属系统自带，`/usr/bin/`）：

```bash
drutil list                                    # 设备枚举
drutil status                                  # 当前介质/空白状态/容量
drutil burn -audio track.wav                   # CD-DA 音频烧录
drutil burn image.iso                          # 数据盘
hdiutil burn image.iso                         # 数据盘（备选）
drutil eject
```

### 3.3 无法字节级对拍（必须接受的现实）

本机**没有 .NET**，源项目是 `net10.0-windows` + WPF，**无法构建、无法运行**，因此：

- ❌ 不能拿 C# 输出做 golden file 比对
- ✅ 改用**数学不变量 + 可被 macOS 解析**来验证（见 §7）

### 3.4 已知风险（写代码时要为它们留出结构）

1. **`drutil` 不保证 DAO 字节级控制**：CD 图案依赖"扇区数恰好落位"，`drutil burn -audio` 可能插入间隙/边距，导致图案整体旋转或偏移。→ 设计上必须把"生成"与"烧录"解耦，导出文件永远可用；烧录失败只报错不回滚。
2. 蓝光命名：源项目用 `bd` 作为工程文件里的 token，UI 显示"蓝光"。
3. 符号链接 / 重解析点：源项目一律拒绝（防止越界读文件）。macOS 上用 `URLResourceValues.isSymbolicLink` 同样拒绝。
4. DVD 的 `4 GiB − 1` 单文件上限（ISO9660），BD 的 UDF 没有此限制。

---

## 4. 已定的架构决策（照做，别改）

1. **SwiftPM 多 target，每种介质一个独立 target** —— 这是为了并行开发时互不阻塞编译。**不要合并成一个大 target。**
2. **`swift-tools-version: 6.0` + `swiftLanguageModes: [.v5]`** —— 用 Swift 6 编译器，但退回 Swift 5 语言模式，避免严格并发检查在多作者并行场景下制造大量无谓报错。**不要改成 `.v6`。**
3. 平台 `.macOS(.v14)`。
4. **共享类型只由 lead 写**，介质实现方不得扩展 lead 拥有的类型（避免并行写冲突）。
5. 引擎不依赖 SwiftUI/AppKit（`DiscImageCore` 只用 Foundation + CoreGraphics + ImageIO）；UI 单向依赖引擎。

### 4.1 目录与归属

```
DiscImageStudioMac/
├── Package.swift                 # lead（已存在，见 §4.3）
├── HANDOFF.md                    # 本文件
├── docs/                         # 架构、算法、验证记录
├── Sources/
│   ├── DiscImageCore/            # lead：共享模型、几何、采样、sink、协议
│   ├── DiscImageDvd/             # 工作包 A：ECC/EFMPlus/NRZI/纹理映射/ISO9660
│   ├── DiscImageCd/              # 工作包 B：延迟交织/WAV/CUE/数据盘
│   ├── DiscImageBluRay/          # 工作包 C：17PP/EDC/LDC-BIS/UDF2.01
│   ├── DiscImageBurning/         # 工作包 E：drutil/hdiutil 封装
│   ├── DiscImageUI/              # 工作包 D：SwiftUI 五工作区
│   ├── DiscImageStudioApp/       # lead：@main 薄壳（依赖 UI）
│   └── DiscImageCLI/             # lead：discimage-cli
└── Tests/
    ├── DiscImageCoreTests/       # lead
    ├── DiscImageDvdTests/        # 工作包 A
    ├── DiscImageCdTests/         # 工作包 B
    ├── DiscImageBluRayTests/     # 工作包 C
    └── DiscImageUITests/         # 工作包 D（离屏渲染快照）
```

### 4.2 当前仓库状态（**接手时先核对**）

已完成并已提交（commit `chore: scaffold Swift package layout`）：

- `git init` 完成，`.gitignore` 已写
- `Package.swift` 已写好（内容见 §4.3）
- 上述 `Sources/`、`Tests/` 目录已建（**全部为空**）
- `docs/` 已建（空）

**因此现在 `swift build` 会失败** —— 空 target 目录 + CLI 里对未实现模块的引用。接手第一步见 §5。

### 4.3 `Package.swift` 现有内容

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiscImageStudioMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DiscImageStudio", targets: ["DiscImageStudioApp"]),
        .executable(name: "discimage-cli", targets: ["DiscImageCLI"]),
        .library(name: "DiscImageCore", targets: ["DiscImageCore"]),
        .library(name: "DiscImageDvd", targets: ["DiscImageDvd"]),
        .library(name: "DiscImageCd", targets: ["DiscImageCd"]),
        .library(name: "DiscImageBluRay", targets: ["DiscImageBluRay"]),
        .library(name: "DiscImageBurning", targets: ["DiscImageBurning"]),
        .library(name: "DiscImageUI", targets: ["DiscImageUI"]),
    ],
    targets: [
        .target(name: "DiscImageCore"),
        .target(name: "DiscImageDvd", dependencies: ["DiscImageCore"]),
        .target(name: "DiscImageCd", dependencies: ["DiscImageCore"]),
        .target(name: "DiscImageBluRay", dependencies: ["DiscImageCore"]),
        .target(name: "DiscImageBurning", dependencies: ["DiscImageCore"]),
        .target(name: "DiscImageUI", dependencies: [
            "DiscImageCore", "DiscImageDvd", "DiscImageCd",
            "DiscImageBluRay", "DiscImageBurning", "DiscImageCLI"
        ]),
        .executableTarget(name: "DiscImageCLI", dependencies: [
            "DiscImageCore", "DiscImageDvd", "DiscImageCd", "DiscImageBluRay"
        ]),
        .executableTarget(name: "DiscImageStudioApp", dependencies: ["DiscImageUI", "DiscImageCore"]),
        .testTarget(name: "DiscImageCoreTests", dependencies: ["DiscImageCore"]),
        .testTarget(name: "DiscImageDvdTests", dependencies: ["DiscImageDvd", "DiscImageCore"]),
        .testTarget(name: "DiscImageCdTests", dependencies: ["DiscImageCd", "DiscImageCore"]),
        .testTarget(name: "DiscImageBluRayTests", dependencies: ["DiscImageBluRay", "DiscImageCore"]),
        .testTarget(name: "DiscImageUITests", dependencies: ["DiscImageUI", "DiscImageCore"]),
    ],
    swiftLanguageModes: [.v5]
)
```

> 若发现某个 target 目录仍为空导致构建失败：SwiftPM 要求 target 目录存在且至少有一个源文件。给每个 target 先放一个占位文件，或临时从 `Package.swift` 里摘掉还没开工的 target。

---

## 5. 共享 Core 的接口草案（先落这部分，再并行）

下面这些类型是**所有工作包的共同依赖**，必须先由 lead 写进 `Sources/DiscImageCore/`。已按源项目的实际语义设计好，可直接使用：

```swift
// DiscError.swift
public enum DiscError: Error, LocalizedError, Equatable {
    case invalidGeometry(String), unsupported(String), io(String)
    case encoding(String), missingPayload(String)
}

// DiscFamily.swift
public enum DiscFamily: String, Codable, CaseIterable, Sendable {
    case cd, dvd, bluRay = "bd"
    public var displayNameZH: String          // "CD" / "DVD" / "蓝光"
    public static func fromProjectToken(_:) -> DiscFamily?   // 兼容 "cd"/"dvd"/"bd"
}

// SpiralModel.swift —— 三分支共用的阿基米德螺旋
public struct SpiralModel: Sendable, Equatable {
    public let innerRadiusMm, outerRadiusMm: Double
    public let totalSectors: Int
    public let totalLengthMm: Double
    public var pitchMm: Double                 // 环带面积 / 总长
    public var totalTurns: Double              // (ro - ri) / pitch
    public var sectorsPerTurn: Double
    public func turnsAt(radiusMm:) -> Double   // 面积线性：turns * (r²-ri²)/(ro²-ri²)
    public func radiusAt(turns:) -> Double
    public func sectorCoordinate(radiusMm:) -> Double
    public func sectorCoordinate(radiusMm:angleRadians:) -> Double   // 角度按 +x 轴逆时针
}

// DiscGeometry.swift
public struct DiscGeometry: Codable, Equatable, Sendable {
    public var family: DiscFamily
    public var innerRadiusMm, outerRadiusMm: Double
    public var sectors: Int
    public var linearVelocityMmPerSecond: Double   // CD
    public var channelBitLengthNm: Double          // DVD
    public var pitchLinear, pitchQuadratic, pitchCubic: Double   // DVD 三次轨距
    public var invertMapping: Bool                 // BD
    public static let dvdChannelBitsPerSector = 38_688
    public static let bluRayChannelBitsPerCluster = 962_136
    public static let bluRayChannelBitLengthNm = 74.5
    public static let bluRaySingleLayerSectors = 12_219_392
    public var totalLengthMm: Double               // 见 §2.2 三条公式
    public var spiral: SpiralModel
    public func pitchFactor(normalizedRadius:) -> Double
    public var hasCubicPitch: Bool
    public func validate() throws                  // DVD %16；BD %32 且 ≤12,219,392 且 ro≤60 且无三次轨距
}

// ToneProfile.swift —— 影调（与介质无关）
public struct ToneProfile: Codable, Equatable, Sendable {
    public var ditherStrength: Double   // 0...100，新工程默认 75
    public var levels: Int              // CD 可为 2/4；DVD/BD 固定 2
    public var brightness: Int          // -64...64
    public var srgbLinearization: Double
}

// RasterImage.swift —— RGBA8，**预乘 alpha**（与黑底合成后即为盘面亮度）
public struct RasterImage: Sendable {
    public let width, height: Int
    public let pixels: [UInt8]                      // RGBA 预乘
    public init(width:height:pixels:)
    public static func load(contentsOf:) throws -> RasterImage    // ImageIO
    public func scaled(maxDimension:) -> RasterImage
    public func luminance(x:y:) -> Double                        // 0...255
    public func luminance(bilinearX:bilinearY:) -> Double
}

// DiscProjection.swift —— 方形画布 ↔ 盘面极坐标
public struct DiscProjection: Sendable {
    public let canvasSize: Int
    public let imageOuterRadiusMm: Double     // CD 默认 57.5；DVD/BD = 外半径
    public var mmPerPixel: Double
    public func polar(canvasX:canvasY:) -> (radiusMm: Double, angleRadians: Double)
    public func canvasPoint(radiusMm:angleRadians:) -> (x: Double, y: Double)
}

// SequentialSink.swift —— 只能前向写（刻录流不可 Seek），回退即抛错
public protocol SequentialSink: AnyObject {
    var position: Int64 { get }
    func write(_ bytes: UnsafeRawBufferPointer) throws
    func pad(to position: Int64, with byte: UInt8) throws
}
public final class FileSequentialSink: SequentialSink { /* FileHandle 包装 */ }
public final class DataSequentialSink: SequentialSink { /* 内存，用于测试 */ }

// FileTree.swift —— 目录扫描（拒绝符号链接），内外圈放置
public struct FileTreeEntry: Sendable { public let relativePath: String; public let sourceURL: URL; public let isDirectory: Bool }

// Pipeline.swift
public struct DiscProgress: Sendable { public var stage, message: String; public var fraction: Double? }
public struct GenerationRequest: Sendable {
    public var geometry: DiscGeometry
    public var tone: ToneProfile
    public var image: RasterImage
    public var dataDirectory: URL?          // nil = 纯绘图
    public var dataAtOuterRing: Bool
    public var volumeLabel: String
    public var clockwise: Bool              // DVD 用 CW
}
public struct GenerationResult: Sendable { public var byteCount: Int64; public var summary: String }
public protocol DiscImageGenerator: Sendable {
    var family: DiscFamily { get }
    func generate(
        _ request: GenerationRequest,
        to sink: SequentialSink,
        progress: @Sendable (DiscProgress) -> Void
    ) throws -> GenerationResult
}
```

---

## 6. 五个可并行工作包

> 全部**只依赖 §5 的 Core**。写作用域互不重叠，可以同时开工。
> 每个包都要自带测试；用 `swift build --target <自己的 target>` 验证，**不要**修别人的文件。

### A. DVD 引擎（`DiscImageDvd` + `DiscImageDvdTests`）

- **必须实现**：扰码器、ECC（PI/PO，含增量重建）、EFMPlus（含双流 DSV 选择与 SYNC 替换）、NRZI、16 扇区 Block 组装、图片→land 数目标映射、**快速纹理映射写盘路径**（`0xA5`/`0x92`）
- **附带**：`ISO9660` 写入器（主 VD + Joliet SVD + 路径表 + 目录记录，支持内圈/外圈文件放置、Unicode 名、拒绝符号链接、单文件 ≤ 4 GiB−1）。CD 数据盘会复用它。
- **不要求**：beam search 约束求解器（`full`/`state-control` 模式）——留待第二轮
- **验收**：每扇区 38688 通道位；每 Block 619008 位；PI 208 行 / PO 172 列零余数；RLL(2,10) 全部游程落在 3T–11T；NRZI 电平数正确；生成 ISO 能被 `hdiutil attach` 挂载并列出文件

### B. CD 引擎（`DiscImageCd` + `DiscImageCdTests`）

- **必须实现**：CD 几何与采样、灰阶映射（2 阶 `0x0D/0xAA`，4 阶 `0x0D/0x10/0x63/0xAA`）、112 帧环形延迟交织（offset 72…2592）、2352 字节扇区输出、WAV（小端 + 44 字节 RIFF）与 CUE、RAW（大端）
- **数据盘模式**：选文件夹时走 ISO9660 Mode 1（依赖工作包 A 的 ISO 写入器）→ 用 task 依赖排在 A 之后
- **验收**：WAV 头正确、CUE 可被 `drutil burn -audio` 接受；交织后逻辑字节位置可复现；尾部丢弃量 1318–1332

### C. 蓝光引擎（`DiscImageBluRay` + `DiscImageBluRayTests`）

- **必须实现**：17PP 编码、EDC(4B)、LDC RS(248,216)×304、BIS RS(9,5)+RS(62,30)、28 个 DC 控制位、RUB 组装、3T/6T 字节映射（`0xAA`/`0x44` + 极性反转）、LDC 交织位置映射、32 扇区簇对齐
- **附带**：UDF 2.01 写入器（≥640 扇区且 %32；> 4 GiB 文件按 `0x3ffff800` 拆 extent；分区外图案区）；sidecar JSON
- **验收**：RLL(1,7)；RS 校验子为零；簇 = 958,272 bit / RUB 962,136 bit；32×2052 = 304×216 的布局断言；生成 ISO 可被 `hdiutil attach`

### D. SwiftUI GUI（`DiscImageUI` + `DiscImageUITests`）

- **六个页面**：主页（模板 + 最近工程）、设计、预览、导出、刻录、标定
- **设计页**：mm 坐标系图层画布（拖动/缩放/旋转）、图片导入、影调面板（抖动 0–100%、亮度 ±64、伽马、CD 灰阶 2/4 阶、BD 极性）、合成图 8192 px 导出 / 2048 px 预览
- **预览页**：设计投影 + 成品读回；文件区用黄色标出
- **导出页**：写 ISO / WAV+CUE / RAW，进度与取消
- **刻录页**：设备枚举、空白检查、速度选择、二次确认
- **工程文件** `.discproj`（JSON，camelCase，schemaVersion 2）：`name / discFamily / geometry / layers / outputs / calibrationSessionPath / thumbnailPngBase64 / createdUtc / modifiedUtc / tone / bluRay`
- **验收**：用 `ImageRenderer` 离屏渲染主页与设计页到 PNG（这就是 UI 回归手段，没有像素基线）

### E. 刻录封装 + 工程化（`DiscImageBurning` + docs）

- `BurnService` 协议 + `DrutilBurner` 实现：`drutil list` 解析设备、`drutil status` 判空白/容量、`drutil burn -audio` / `hdiutil burn`、取消与错误翻译
- 中文错误文案、进度解析、失败后"盘片可能报废"提示
- `README.md`、`docs/ARCHITECTURE.md`、`docs/VALIDATION.md`、GitHub Actions（`macos-latest`，跑 build + test）

---

## 7. 验收标准（完成定义）

```bash
swift build                                   # 全绿，0 error
swift test                                    # 全绿
swift run discimage-cli generate --family dvd --image in.png --out out.iso
hdiutil attach out.iso && ls /Volumes/        # 能挂载 → 文件系统结构正确
swift run DiscImageStudio                     # 打开 GUI
```

UI 验收额外项：离屏渲染主页 + 设计页 PNG 成功。

**注意**：这台机器**没有真实刻录机**，刻录路径只能验证到"命令构造正确 + 错误处理正确"，不能验证实际烧录。

---

## 8. 源仓库查阅索引

| 想查什么 | 去哪 |
|---|---|
| 架构分层与扩展规则 | `docs/ARCHITECTURE.md` |
| DVD 求解器与编码链约定 | `docs/DVD_ENGINE.md` |
| 蓝光物理模型与生成/刻录链路 | `docs/ADDING_BLURAY.md` |
| 蓝光 3T/6T 字节密度实验 | `docs/BLURAY_BYTE_DENSITY.md` |
| CD 音轨格式/字节序/重影排查 | `docs/CD_AUDIO_COMPATIBILITY.md` |
| 物理模型审计（CD 缺陷、时序、介质匹配） | `docs/PHYSICAL_MODEL_AUDIT.md` |
| 验证记录与实盘边界 | `docs/VALIDATION.md` |
| 盘片预设格式 | `docs/DISC_PRESETS.md` |
| 标定三分法与三次轨距 | `docs/CALIBRATION.md` |
| 内置预设 JSON | `src/DiscImageStudio.Core/Presets/built-in-disc-presets.json` |
| DVD 编码实现 | `src/DvdImageSolver/Encoding/` |
| CD 交织实现 | `src/DiscImageStudio.Cd/CddaInterleaver.cs`、`CddaInterleaveTable.cs` |
| 蓝光编码实现 | `src/DiscImageStudio.BluRay/Encoding/` |
| ISO9660 / UDF 写入器 | `src/DiscImageStudio.Iso/` |

---

## 9. 接手第一小时建议动作

1. `cd ~/CodingProjects/DiscImageStudioMac && swift build` —— 确认失败原因并记录
2. 按 §5 把 `DiscImageCore` 写全，`swift build --target DiscImageCore` 通过
3. 给每个空 target 放最小占位文件，让 `swift build` 整体通过（占位文件之后由各工作包替换）
4. 补 `Tests/DiscImageCoreTests`：螺旋公式对照（§2.2 那张表）+ 几何校验用例
5. 再按 §6 拆工作包并行；**每个包一个独立写作用域，先定 task 依赖**
6. 每完成一个包就跑 `swift build --target <pkg>`，最后由 lead 跑全量 `swift build` + `swift test`

---

## 10. 明确不要做的事

- ❌ 不要试图移植 Windows 刻录层（IMAPI2 / COM / MMC 直写）
- ❌ 不要移植 beam search 求解器（首版用快速纹理映射即可）
- ❌ 不要手写 EFMPlus 表（用 §2.4 的脚本转换法）
- ❌ 不要为了"逐字节等价"去猜源项目输出（无法验证，只验证数学不变量）
- ❌ 不要把各介质合并进一个 target（会让并行开发互相阻塞）
- ❌ 不要在 `DiscImageCore` 里引入 SwiftUI / AppKit

---

## 11. 首版落地记录（2026-11-02）

> 这一节是**移植完成后**补写的，记录实际结果、与 §4.3 的偏差、以及没有硬件时到底验证到了哪一步。
> 上游规格（§2）与架构决策（§4）未改动。

### 11.1 完成范围

| 工作包 | 交付 | 测试 |
|---|---|---|
| Core（lead） | 几何/螺旋/影调/投影/RasterImage/SequentialSink/FileTree/预设/Pipeline 契约 | 56 用例 |
| A DVD | 扰码 + ECC(PI/PO 增量重建) + EFMPlus(双流 DSV + SYNC 替换) + NRZI + 快速纹理映射 + `Iso9660Writer` | 47 用例 |
| B CD | 几何采样 + 2/4 阶灰阶 + 112 帧延迟交织 + WAV/CUE（小端）+ RAW（大端）+ Mode 1 数据盘 | 61 用例 |
| C 蓝光 | EDC + LDC/BIS + 17PP + 28 位 DC 控制 + RUB + 3T/6T + UDF 2.01 + sidecar | 36 用例 |
| D GUI | 六页面（主页/设计/预览/导出/刻录/标定）+ `.discproj` v2 + ImageRenderer 离屏回归 | 80 用例 |
| E 刻录 | `BurnService`/`DrutilBurner`/`MockBurnService` + 命令构造/解析纯函数 + 文档 + CI | 60 用例 |
| CLI（lead） | `discimage-cli generate/presets/geometry/info`，三引擎已接线 | 端到端脚本 |

合计约 1.57 万行 Swift 源码 + 0.66 万行测试。

### 11.2 与 HANDOFF §4.3 的两处必要偏差（SwiftPM 硬约束，已在 `Package.swift` 与 `docs/ARCHITECTURE.md` 注明）

1. **`DiscImageUI` 不依赖 `DiscImageCLI`**：SwiftPM 不允许 library target 依赖 executable target。UI 直接依赖三引擎 + 刻录封装，符合「UI 单向依赖引擎」。
2. **`DiscImageCd` 依赖 `DiscImageDvd`**：CD 数据盘模式复用 A 的 `Iso9660Writer`（§6.B 的要求），只能靠 target 依赖表达。

另：新增 `Tests/DiscImageBurningTests` target（E 需要）。

### 11.3 验收证据（`scripts/verify.sh`，本机实测）

```
✓ 构建通过（swift build，0 error）
✓ 测试全绿（340 个用例，0 failure；蓝光挂载用例默认跳过，设 BLURAY_MOUNT_TEST=1 可开）
✓ DVD 纯绘图生成
✓ DVD 数据盘生成 + hdiutil 挂载成功，内容含 readme.txt
✓ 蓝光数据盘生成 + hdiutil 挂载成功，内容含 readme.txt
✓ 蓝光 sidecar JSON
✓ CD 生成 WAV + 旁写 CUE + RIFF 头正确
```

`discimage-cli generate` 的 256/640 扇区小几何约 0.3–1.1 s（debug）；GUI 用
`.build/debug/DiscImageStudio` 可启动并常驻（无崩溃输出）。

### 11.4 有意不做（与 §6/§10 一致）

- DVD beam search / state-control 求解器（只做快速纹理映射）。
- Windows 刻录层（IMAPI2/COM/MMC）——改用 `drutil` / `hdiutil`。
- CD 的 CIRC 与 EFM（源项目本身就没有）。
- 与源项目输出逐字节对拍（本机无 .NET，改用数学不变量 + 系统可挂载）。

### 11.5 本机无法验证的部分（必须写进任何对外说明）

1. **真实烧录**：本机没有刻录机、没有空白光盘；刻录链路只验证到「命令构造 + 输出解析 + 错误翻译 + 取消措辞」。
2. **实盘光学极性**：DVD 的 0xA5/0x92 与 BD 的 3T/6T 都是编码统计约定，不是实测反射率；极性反转只在数据模型里表达。
3. **图案在真盘上的对齐**：`drutil` 不保证 DAO 字节级控制（§3.4 风险 1），图案可能整体旋转/偏移。
4. **性能**：debug 下整盘 DVD/CD 是小时级、分钟级（如 cd-74 整盘 debug ≈27 分钟）；release 快一个数量级，但未做并行生成优化。

### 11.6 后续可做（优先级从高到低）

1. 引擎发布版提速：SIMD 采样 + 多核按块并行（按序写 sink）。
2. GUI 设计页 8192 px 合成放到后台队列（目前主线程同步，会卡几秒）。
3. 预览页「成品读回」接引擎真实读回产物（目前显示源灰度 + 字节数粗估的文件区）。
4. CD 旁写元数据（`cd-da-track-v1` / `cd-rom-mode1-v1`），供读回按实测几何还原。
5. 拿到刻录机后：实盘标定 → 更新预设 → 用 `docs/VALIDATION.md` 的步骤回填真实证据。
