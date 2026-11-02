# 架构说明

> 本文记录 DiscImageStudioMac 的分层、数据流与几个「看起来奇怪但必须这样」的决策。
> 编码规格（ECC 参数、EFMPlus、17PP、螺旋几何……）不在本文，见 [HANDOFF.md](../HANDOFF.md) §2；
> 验证手段见 [VALIDATION.md](VALIDATION.md)。

## 1. 分层与 target 划分

SwiftPM 多 target，**每种介质一个独立 target**。这不是洁癖，是并行开发的必要条件：
五个工作包同时写代码时，谁的 target 编译不过，不应该拖住别人的 `swift build --target`。

| target | 归属 | 职责 | 依赖 |
|---|---|---|---|
| `DiscImageCore` | 共享层 | 与介质无关的模型：`DiscFamily` / `DiscGeometry` / `SpiralModel` / `DiscProjection` / `ToneProfile` / `RasterImage` / `SequentialSink` / `GenerationRequest` / `DiscImageGenerator` | 仅 Foundation + CoreGraphics + ImageIO |
| `DiscImageDvd` | 工作包 A | 扰码、ECC(PI/PO)、EFMPlus、NRZI、Block 组装、纹理映射、ISO9660 写入器 | Core |
| `DiscImageCd` | 工作包 B | CD 几何采样、灰阶、112 帧环形交织、2352 字节扇区、WAV/CUE、数据盘 Mode 1 | Core, **Dvd**（见 §4） |
| `DiscImageBluRay` | 工作包 C | EDC、LDC/BIS、17PP、DC 控制、RUB 组装、3T/6T 映射、UDF 2.01、sidecar | Core |
| `DiscImageBurning` | 工作包 E | `drutil` / `hdiutil` 封装：命令构造、输出解析、错误翻译、取消与超时 | Core |
| `DiscImageUI` | 工作包 D | SwiftUI 五工作区（主页/设计/预览/导出/刻录）+ 标定页 | Core + 三引擎 + Burning |
| `DiscImageCLI` | 薄前端 | `discimage-cli generate …`，把命令行参数翻译成 `GenerationRequest` | Core + 三引擎 |
| `DiscImageStudioApp` | 薄壳 | `@main`，只负责把 `DiscImageUI` 的根视图挂起来 | UI + Core |

依赖方向是单向的、无环的：

```
                    ┌──────────────┐
                    │ DiscImageCore│◄──────────────┐
                    └──────┬───────┘               │
        ┌──────────────┬───┴────────┬──────────────┴─┐
        ▼              ▼            ▼                ▼
  DiscImageDvd   DiscImageCd   DiscImageBluRay  DiscImageBurning
        │              │            │                │
        └──────┬───────┴────────────┴────────────────┘
               ▼
         DiscImageUI ──► DiscImageStudioApp
               │
        （DiscImageCLI 平行于 UI，不依赖 UI，也不被 UI 依赖）
```

规则：

- **`DiscImageCore` 不引入 SwiftUI / AppKit**，引擎可以在没有界面、没有窗口服务器的环境里跑（CI、命令行、离屏测试）。
- **共享类型只由 Core 提供**，各介质 target 不得扩展 Core 拥有的类型，避免并行写冲突。
- **Swift 6 编译器 + `swiftLanguageModes: [.v5]`**：多作者并行时，严格并发检查会制造大量与业务无关的报错；退回 Swift 5 语言模式，同时保留 Swift 6 工具链。

## 2. 数据流

### 2.1 生成（图片 → 映像文件）

```
用户输入（.discproj / UI 状态 / CLI 参数）
   │  DiscGeometry（含盘片预设、三次轨距）
   │  ToneProfile（抖动/亮度/伽马/灰阶档位）
   │  RasterImage（预乘 RGBA8）
   │  dataDirectory?（nil = 纯绘图）
   │  GenerationOutputFormat（iso / wav / raw）
   ▼
GenerationRequest ──► DiscImageGenerator.generate(_:to:progress:)
                          │  阶段：geometry → mapping → ecc → modulation → filesystem → finalize
                          │  每个阶段边界检查 CancellationFlag
                          ▼
                     SequentialSink（只能前向写：刻录流不可 seek）
                          │
        ┌─────────────────┼──────────────────┬─────────────────────┐
        ▼                 ▼                  ▼                     ▼
   out.iso          out.wav + out.cue     out.raw          out-bd-r-image-v1.json
  (DVD/BD/数据盘CD)   (CD-DA，44B RIFF)   (CD 裸扇区，大端)     (蓝光旁写 sidecar)
```

要点：

- `SequentialSink` 是**只能前向写**的抽象（`FileSequentialSink` / `DataSequentialSink` / `NullSequentialSink`）。回退写会抛错——这样同一份引擎代码既能落盘，也能在测试里写内存，还能只跑编码不落盘（预览/测速）。
- 进度通过 `DiscProgress`（stage / message / fraction）回调上报，`ProgressThrottle` 负责节流，避免 UI 被淹没。
- 取消用 Core 的 `CancellationFlag`：引擎只在阶段边界检查，不强杀线程；刻录层的取消是另一套机制（子进程终止，见 §5）。

### 2.2 刻录（映像文件 → 盘片）

```
ISO / WAV+CUE / RAW
   ▼
BurnService（协议）
   ├── DrutilBurner ──► BurnCommandBuilder（纯函数：构造 BurnCommand）
   │                        │
   │                        ▼
   │                   CommandExecutor（SystemCommandExecutor：Process）
   │                        │
   │                        ▼
   │                 /usr/bin/drutil · /usr/bin/hdiutil
   │                        │
   │                        ▼
   │                   DrutilParser（纯函数：解析输出 / 进度 / 失败分类）
   └── MockBurnService（内存假实现：UI 预览、无光驱开发、测试）
```

**生成与烧录彻底解耦**：刻录层只吃已经存在的文件。刻录失败的推荐动作永远是「换张盘再刻一次同一个文件」，而不是「重新生成」。这也规避了 `drutil` 不保证 DAO 字节级控制带来的不确定性——图案可能整体旋转/偏移，但文件本身没错。

## 3. 为什么 UI 不依赖 CLI

HANDOFF §4.3 的初始稿里，`DiscImageUI` 的依赖列表包含 `DiscImageCLI`。这在 SwiftPM 里**根本编译不过**，也是架构上不该做的事：

1. **SwiftPM 硬性限制**：library target 不能依赖 executable target（`DiscImageCLI` 是 `executableTarget`）。所以 `Package.swift` 里 UI 的依赖是
   `Core + Dvd + Cd + BluRay + Burning`，没有 CLI。
2. **UI 需要的是 Swift API，不是命令行**。界面要拿几何、影调、进度回调、取消令牌、`BurnService`——这些都在引擎库里。让界面去 spawn 一个 CLI 进程，就得重新发明参数转义、stdout 进度解析、取消信号传播、退出码翻译，还会让打包后的 `.app` 依赖一个外部可执行文件。
3. **CLI 与 GUI 是同一批引擎的两个前端**。共享的代码在 `Core` 与各引擎 target 里；`DiscImageCLI` 只做「参数 → `GenerationRequest`」的翻译。两个前端谁都不该是对方的依赖。

## 4. 为什么 CD 依赖 DVD

`Package.swift` 里 `DiscImageCd` 的依赖是 `["DiscImageCore", "DiscImageDvd"]`。原因只有一个：**CD 的数据盘模式复用 DVD 工作包交付的 ISO9660 写入器**（HANDOFF §6.B 明确要求「依赖工作包 A 的 ISO 写入器」）。

- 纯绘图（WAV/CUE/RAW）路径完全不碰 DVD 代码；只有 `dataDirectory != nil` 的 CD 数据盘才走 ISO9660 Mode 1。
- 不存在循环依赖：`DiscImageDvd` 不依赖 `DiscImageCd`。
- 代价是并行开发时的顺序约束：CD target 要等 Dvd target 能编译。这也是任务板把「CD 数据盘模式」排在 DVD 之后的原因。

HANDOFF §4.3 原稿只写了 `DiscImageCd: ["DiscImageCore"]`，与 §6.B 的要求矛盾。以 §6.B 的功能要求为准，用 target 依赖表达。

## 5. 刻录层设计（`DiscImageBurning`）

### 5.1 只依赖一个协议

```swift
public protocol BurnService: Sendable {
    func listDevices() async throws -> [DiscDevice]
    func status(deviceID: String?) async throws -> DiscStatus
    func burnAudio(trackURL: URL, deviceID: String?) async throws
    func burnImage(imageURL: URL, deviceID: String?) async throws
    func eject(deviceID: String?) async throws
}
```

界面只认这个协议。真机用 `DrutilBurner`，没有光驱/预览用 `MockBurnService`。`MockBurnService` 会记录每次调用（`calls`），可以断言「用户点取消前到底调了哪些操作」。

### 5.2 三层拆分：命令构造 / 执行 / 解析

| 层 | 类型 | 是否碰系统 | 为什么这样切 |
|---|---|---|---|
| 命令构造 | `BurnCommandBuilder` | 否，纯函数 | 「该敲哪条命令」是纯知识，可以在没有光驱、甚至没有 macOS 的 CI 上断言 |
| 执行 | `CommandExecutor` / `SystemCommandExecutor` | 是（`Process`） | 唯一允许 `Process` 的地方；抽成协议后，`DrutilBurner` 的全部逻辑都能用 `FakeExecutor` 测 |
| 解析 | `DrutilParser` | 否，纯函数 | `drutil` 文本输出不是 API，必须容错；用固定样本回归「有设备/无设备/空白盘/非空白盘/无盘」 |

### 5.3 三条来自 man page 的硬约定

1. **`-drive` 必须放在动词前面**：`drutil -drive 1 burn …`，不是 `drutil burn -drive 1 …`（drutil(1)：「Drive selection arguments must appear before individual arguments」）。
2. **不指定 `-drive` 时 `drutil` 对所有候选光驱执行同一件事**。所以设备多于一台时，`DrutilBurner` 直接抛 `ambiguousDevices`，不替用户猜——烧错盘的代价太高。
3. **hdiutil 的 `-device` 要的是 `hdiutil burn -list` 给出的 OpenFirmware 路径**，不是 drutil 的设备序号。所以 `imageTool: .hdiutil` 时不接受 `deviceID`（抛 `invalidDeviceID`），默认数据盘刻录用 `drutil`，设备选择始终可信。即使走 hdiutil，预检仍然先 `drutil list` 枚举一遍：没有刻录机、或有多台却没人选，都在烧之前拦下。

### 5.4 先预检，再烧盘

每次刻录前跑一次 `drutil status`，按顺序检查：**有盘 → 空白 → 可写 → 容量够**。任何一项不满足就在烧之前抛错，并给出可执行的中文文案（放盘 / 换空白盘 / 换大容量盘）。让 drutil 写到一半才报错等于白毁一张盘。

### 5.5 取消与超时

- 查询命令超时 60 秒，刻录默认 2 小时（BD-R 25 GB 2x 就要 40 分钟以上）。
- 取消时 `SystemCommandExecutor` 轮询 `process.isRunning`（不用 `waitUntilExit()` 阻塞），任务被取消就 `SIGTERM` → 3 秒后 `SIGKILL`。
- 只有 `writesDisc == true` 的命令（真正的 `burn`）才会在看到取消/超时时提示「盘片可能报废」；查询阶段取消明确告诉用户「盘片没被写过」。

### 5.6 错误文案

`BurnError` 的每个 case 都有两句中文：`errorDescription`（发生了什么）与 `recoverySuggestion`（现在该做什么）。五类必答问题是：无驱动器、非空白盘、容量不足、权限不足、命令缺失。文案里不出现英文 errno 原文；原始输出的最后几行放在 `toolFailed` 里，供用户回报时复制。

## 6. UI 与引擎的单向依赖

`DiscImageUI` 直接持有引擎与 `BurnService`，同进程调用；没有 XPC、没有进程边界（首版刻意如此：编码是纯计算，放同进程最省事，也便于离屏渲染测试）。UI 的回归手段是 `ImageRenderer` 离屏渲染主页/设计页到 PNG——没有像素基线，只保证「能渲染、不崩、布局可达」。

## 6.1 标定闭环（`DiscImageCore/Calibration`）

标定回答的是「这张盘片的轨道到底长什么样」，不是「编码对不对」。上游用三步闭环，
本移植照 schema 6 的现行流程实现（**不**移植已废弃的格子图案 target）：

```
生成标定盘 ──► 拍照 ──► 单应矫正 ──► 点一条径向曲线 ──► 反推 (ri, ro, c1..c3) ──► 写回几何
```

| 环节 | 位置 | 要点 |
|---|---|---|
| 图案 | `CalibrationPattern` | 内置 `target_slim.png`（九条细同心圆 + 十字线）；按**生成外半径**缩放，再裁掉内半径以内的环带；与普通图片同一条坐标映射 |
| 矫正 | `CalibrationPhotoRectifier` | 把「盘片实体外缘（60/40 mm）」与「中心孔（7.5 mm）」两条同心圆联合拟合到**一个单应矩阵**；尺度来自盘片规格，不需要手量 |
| 反推 | `CalibrationCrossFitter` | 单条径向曲线 → 内外半径 + 整体转角 + 三次轨距系数；`p0` 由总轨长约束自动确定；整条 trace 只允许一个整数圈偏移 |
| 判定 | `CalibrationFitResult` | rms / max / 离群点；平均 > 0.35 mm 或最大 > 0.8 mm 不可应用；搜索框自动扩大（±0.02 → 0.1 → 0.5 mm）时给警告 |
| 持久化 | `CalibrationSessionStore` | `.calibration.json`（schema 6）：生成快照 + 内嵌照片 + 轮廓点 + 曲线点；原子写入、读取校验 |

**为什么要闭环**：几何参数（尤其 DVD 的三次轨距）决定了图案在盘面上的物理位置。
用错参数会整体旋转/缩放/径向漂移，而这只能从盘面本身测出来——所以标定是
「先于求解器」的优先级：它决定我们看到的图案是否就是设计的那张。

不可观测性：固定线密度下，照片尺度、半径与轨距形状可能互相补偿，单条曲线的
四个系数**不唯一**；界面因此要求对照整条预测曲线，而不是只看 rms。

## 7. 扩展指引

新增一种介质（例如 BD-XL）：

1. 新建 `Sources/DiscImageX/`，依赖 `DiscImageCore`（需要复用 ISO/UDF 写入器时再依赖对应 target）；
2. 实现 `<X>ImageGenerator: DiscImageGenerator`，在 `family` 里报自己的 `DiscFamily`；
3. 在 `Package.swift` 加 target 与 testTarget，`DiscImageUI` / `DiscImageCLI` 各自接线；
4. 在 `docs/VALIDATION.md` 补该介质的数学不变量。

不要在 `DiscImageBurning` 里新增第二种刻录后端来「顺便支持」——先确认 `drutil` / `hdiutil` 确实做不到，再讨论是否引入 IOKit（HANDOFF §3.2 明确不上裸 SCSI）。
