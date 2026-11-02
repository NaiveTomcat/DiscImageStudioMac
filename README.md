# DiscImageStudioMac

把一张图片编码进 **CD / DVD / 蓝光** 的盘面物理层，刻录之后盘面上能**用肉眼看到**这幅图。

这是 Windows 版 [Disc Image Studio](https://github.com/JiaFeiMiao-K-Cat/DiscImageStudio)（C# / .NET 10 / WPF，约 6 万行）的 **macOS 原生移植版**：SwiftUI 界面 + 纯 Swift 编码引擎 + 基于系统 `drutil` / `hdiutil` 的刻录封装。

> **这是移植首版，不是功能等价版。** 下面「首版范围与成熟度」一节把缺口写清楚了——尤其是 DVD 只做快速纹理映射、CD 没有 CIRC/EFM、蓝光是实验性这三条。

---

## 首版范围与成熟度

| | DVD | CD | 蓝光（BD-R 单层） |
|---|---|---|---|
| 成熟度 | ★★★★★ 主力 | ★★★☆☆ 可用，有疑点 | ★★☆☆☆ 实验性 |
| 编码链 | 扰码 / ECC(PI+PO) / EFMPlus / NRZI **全部实现** | **只做字节级延迟交织，没有 CIRC、没有 EFM** | 17PP / EDC / LDC+BIS / NRZI / UDF 2.01 **全部实现** |
| 生成算法 | **快速纹理映射**（payload 字节选 `0xA5` / `0x92`） | 直接查表映射 | 直接字节选值（`0xAA` / `0x44` + 极性） |
| 输出 | ISO 映像 | WAV + CUE（CD-DA）／RAW／数据盘 ISO | ISO 映像 + sidecar JSON |
| 实盘证据 | 上游有标定前后实拍对比 | 上游仅一次「无重影」反馈 | 无 |

**首版明确不做的事**（与 HANDOFF 一致，改这些之前先读 `docs/ARCHITECTURE.md`）：

- ❌ **不移植 beam search 约束求解器**。上游 GUI 走的就是「快速纹理映射」，首版只搬这条路。
- ❌ **不移植 Windows 刻录层**（IMAPI2 / COM / MMC 直写）。macOS 上改用 `drutil` / `hdiutil`。
- ❌ 不追求与源项目输出「逐字节对拍」——源项目是 `net10.0-windows` + WPF，在 macOS 上无法构建，所以改用数学不变量 + 系统可解析性验证（见 [docs/VALIDATION.md](docs/VALIDATION.md)）。

## 环境要求

- macOS 14 或更新
- Xcode 16 / Swift 6 工具链（`swift-tools-version: 6.0`，语言模式仍是 Swift 5）
- 无第三方 Swift 包依赖

## 构建与测试

```bash
# 构建指定 target（并行开发时用 SCRATCH 隔离，避免抢 SwiftPM 全局构建锁）
SCRATCH=.build-burn scripts/build.sh --target DiscImageBurning

# 跑某个测试 target
SCRATCH=.build-burn scripts/test.sh --filter DiscImageBurningTests

# 全量
scripts/build.sh
scripts/test.sh
```

`scripts/build.sh` / `scripts/test.sh` 只是 `swift build` / `swift test` 的薄包装：它们把 Clang / SwiftPM 的模块缓存指进工作区的 scratch 目录，并在需要时加上 `--disable-sandbox`（受限沙箱里 SwiftPM 自带的 sandbox-exec 会失败）。**在普通开发机上直接敲 `swift build` / `swift test` 也完全没问题。**

## 运行

```bash
# SwiftUI 应用（主页 / 设计 / 预览 / 导出 / 刻录 / 标定）
swift run DiscImageStudio

# 命令行：从图片生成映像
swift run discimage-cli generate --family dvd --image in.png --out out.iso
swift run discimage-cli generate --family cd --preset cd-80 --image in.png --format wav --out cover.wav
```

生成的映像可以：

```bash
# 数据盘：挂载检查文件系统
hdiutil attach out.iso && ls /Volumes/

# CD 音轨 / 数据盘：交给系统刻录（会真的烧盘，先确认是空白盘）
drutil -drive 1 burn -audio -noverify cover.wav
```

应用内的刻录页只调用系统自带的 `/usr/bin/drutil` 与 `/usr/bin/hdiutil`，不引入 IOKit / 裸 SCSI。**注意 `drutil` 不保证 DAO 的字节级控制**：CD 图案依赖「扇区数恰好落位」，`drutil burn -audio` 可能插入间隙或边距，导致图案整体旋转/偏移。因此生成与烧录在设计上完全解耦——导出的文件永远是可重试的资产，刻录失败只报错、不回滚。

## 没有刻录机时能验证到哪一步

这台开发机和 CI 上的 `macos-latest` **都没有刻录机**。所以：

| 能验证 | 方式 |
|---|---|
| 编码算法 | 数学不变量断言（通道位数、ECC 余数、RLL 游程、交织位置……）见 [docs/VALIDATION.md](docs/VALIDATION.md) |
| 生成的文件系统 | `hdiutil attach` 挂载生成的 ISO / UDF 映像，`ls` 目录与文件内容 |
| WAV/CUE 结构 | 44 字节 RIFF 头、小端 PCM、`FILE ... WAVE` 的 CUE 文本 |
| 刻录命令构造 | 纯函数单测：`-drive` 位置、`-audio`/`-noverify`/`-noeject`、hdiutil 的 `-noverifyburn` |
| `drutil` 输出解析 | 固定样本（有设备 / 无设备 / 空白盘 / 非空白盘 / 无盘）单测 |
| 错误文案与取消 | 假执行器（`FakeExecutor`）驱动 `DrutilBurner`，不启动任何子进程 |

**不能验证**：真实烧录、实盘反射亮度与极性、图案在真盘上的对齐、光驱固件差异。测试与脚本里**一律不调用 `drutil burn` / `hdiutil burn`**。

## 项目结构

```
Sources/
  DiscImageCore/       共享模型：几何、螺旋、投影、影调、光栅图、顺序 sink、生成协议
  DiscImageDvd/        DVD 引擎：扰码、ECC(PI/PO)、EFMPlus、NRZI、纹理映射、ISO9660
  DiscImageCd/         CD 引擎：几何采样、灰阶映射、112 帧环形交织、WAV/CUE、数据盘
  DiscImageBluRay/     蓝光引擎：17PP、EDC、LDC/BIS、RUB、UDF 2.01、sidecar
  DiscImageBurning/    刻录封装：drutil/hdiutil 命令构造与输出解析、错误翻译、取消
  DiscImageUI/         SwiftUI 五工作区 + 标定页
  DiscImageCLI/        discimage-cli
  DiscImageStudioApp/  @main 薄壳
Tests/                 每个 target 对应一个测试 target
docs/                  架构与验证说明
scripts/               构建 / 测试 / 验收 / 打包签名公证脚本
dist/                  打包产物（.app / .dmg，已 gitignore）
```

分层与依赖方向见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 打包分发

```bash
scripts/package.sh          # release 构建 → .app → 签名 → DMG → 公证 → 装订 → Gatekeeper 验收
```

产物在 `dist/`：`DiscImageStudio.app` 与 `DiscImageStudio-<版本>.dmg`（Developer ID 签名 +
hardened runtime + 公证票据）。首次公证需要一次凭据配置，见
[docs/RELEASING.md](docs/RELEASING.md)。

## 文档

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)：target 分层、数据流、为什么 UI 不依赖 CLI、为什么 CD 依赖 DVD、刻录层设计
- [docs/VALIDATION.md](docs/VALIDATION.md)：数学不变量清单、`hdiutil` 挂载验证、**明确写出的不可验证边界**
- [docs/RELEASING.md](docs/RELEASING.md)：打 DMG、Developer ID 签名、公证凭据配置、Gatekeeper 验收
- [HANDOFF.md](HANDOFF.md)：项目唯一的上下文来源（编码规格、盘片预设、架构决策）

## 许可证与原出处

本项目沿用上游的 **GPL-3.0-or-later** 许可。

- 上游项目：**Disc Image Studio**，作者 JiaFeiMiao-K-Cat（Windows / C# / .NET / WPF），本仓库的编码规格、盘片预设与物理模型均来自该项目。
- CD 延迟交织代码的原始出处：**arduinocelentano/cdimage**（经上游转发与改写）。致谢两位作者。
- 编码所依据的标准：ECMA-130（CD）、ECMA-267（DVD-ROM）、ECMA-359（DVD-R）、ISO/IEC 30190（BD-R）、ISO 9660 / Joliet、UDF 2.01。

> 发布前请确认仓库根目录已放入 GPL-3.0 全文 `LICENSE`。
