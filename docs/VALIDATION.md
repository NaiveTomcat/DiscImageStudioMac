# 验证说明

本文回答两个问题：**这台机器上能证明什么**、**什么只能到真盘上才能证明**。

前提：源项目 Disc Image Studio 是 `net10.0-windows` + WPF，本机（macOS，无 .NET）**无法构建、无法运行**，所以：

- ❌ 不能拿 C# 的输出做 golden file 逐字节对拍；
- ✅ 改用**数学不变量**（每扇区通道位、ECC 余数、RLL 游程、交织位置、文件系统结构）证明编码链自洽；
- ✅ 用**系统自带工具**（`hdiutil attach`、`plutil`、WAV/CUE 结构检查）证明生成的容器能被真实软件解析。

另一条硬前提：**本机与 GitHub Actions 的 `macos-latest` 都没有刻录机**。刻录路径只能验证到「命令构造正确 + 输出解析正确 + 错误翻译正确」，**不验证真实烧录**。

---

## 1. 怎么跑

```bash
# 全量
scripts/build.sh
scripts/test.sh

# 单个工作包
SCRATCH=.build-dvd scripts/build.sh --target DiscImageDvd
SCRATCH=.build-dvd scripts/test.sh --filter DiscImageDvdTests

# 生成映像并做挂载验证（手动，见 §3）
scripts/build.sh
swift run discimage-cli generate --family dvd --image in.png --out artifacts/out.iso
hdiutil attach artifacts/out.iso
```

`scripts/*.sh` 只是 `swift build` / `swift test` 的包装（缓存隔离 + `--disable-sandbox`），在普通开发机上直接敲 `swift build` / `swift test` 等价。

CI 与本地跑同一组命令，见 `.github/workflows/ci.yml`。

---

## 2. 数学不变量清单

下面是编码链**必须满足**的数学不变量，也是各测试 target 的目标断言（逐条可在 `swift test` 输出里核对）。任何一条变红都说明编码链被改坏了，而不是「角度差一点」。反过来说：**没列在这里的项目，一律按 §4 当作未验证**。

### 2.1 几何与螺旋（`DiscImageCoreTests`）

| 不变量 | 断言 |
|---|---|
| 总轨道长公式 | CD `L = (N/75)·v`；DVD `L = N·38688·bitLength`；BD `L = (N/32)·962136·74.5e-6` |
| CD 80min 反算螺距 | **1.4329 µm**，且**记录为已知缺陷**（低于 ECMA-130 的 1.5–1.7 µm 下限，源项目遗留问题，不当作正确性目标） |
| DVD 默认反算螺距 | **0.7398 µm** ≈ 0.74 µm ✅ |
| 面积线性 | `turns(r) = totalTurns·(r²−ri²)/(ro²−ri²)` 与其反函数互为逆 |
| 扇区坐标 | `sectorCoordinate(radiusMm:)` 单调、端点落在 0 与 `totalSectors` |
| 几何校验 | DVD 扇区数 %16；BD 扇区数 %32 且 ≤ 12,219,392 且外半径 ≤ 60 mm 且无三次轨距；三次轨距多项式在 0…1 上恒正 |

### 2.2 DVD 编码链（`DiscImageDvdTests`）

| 不变量 | 断言 |
|---|---|
| 扇区 | 每扇区 **38,688** 通道位；26 Sync Frame / 扇区；91 字节 / 1488 bit 每帧 |
| Block | 16 扇区 = **619,008** 通道位；416 帧 |
| ECC | 208×182 矩阵；PI 208 行余数为零；PO 172 列余数为零；数据区 192×172 |
| EFMPlus | 双流 DSV 选择 `|DSV|` 较小者；`|DSV| > 63` 时尝试 SYNC 替换；转换表与 ECMA-267 Annex G 一致 |
| RLL(2,10) | NRZI 后所有游程落在 **3T–11T** |
| 纹理映射 | payload 字节只取 `0xA5`（黑，5 次 transition）/ `0x92`（白，2 次 transition）；旧镜像 `0x66`→0、`0xB9`→85 的回读识别 |
| 固定约定 | Sector Information `0x00`；DVD-R Data Frame RSV 为六个 `0x00`；`PSN = 0x30000 + LBA` |
| ISO9660 | 主 VD + Joliet SVD + 路径表 + 目录记录；单文件 ≤ 4 GiB−1；拒绝符号链接 |

### 2.3 CD 编码链（`DiscImageCdTests`）

| 不变量 | 断言 |
|---|---|
| 扇区 | **2352** 字节/扇区；75 扇区/秒；24 字节/帧 |
| 灰阶 | 二阶 `0x0D` / `0xAA`（`gray < 128` 取 `0x0D`）；四阶 `0x0D / 0x10 / 0x63 / 0xAA` |
| 交织 | 24 字节/帧、112 帧环形延迟线；逻辑字节 `i` → 文件位置 `i + offset(i % 24)`；`offset` 落在 **72…2592** 字节 |
| 尾部 | 交织后末尾丢 **1318–1332** 字节（源项目已知行为，作为断言记录） |
| WAV | 44 字节 RIFF 头 + **小端** PCM（44.1 kHz / 16 bit / 双声道）；旁写 `.cue` 含 `FILE … WAVE` |
| RAW | **大端**字节序 |
| ⚠️ 缺口 | 生成链路**没有 CIRC 校验、没有 EFM 调制**，只做字节级延迟重排。这是源项目的实际状态，不是本移植的遗漏。 |

### 2.4 蓝光编码链（`DiscImageBluRayTests`）

| 不变量 | 断言 |
|---|---|
| 簇 | 32 扇区 = 1 cluster = 1 recording unit；**962,136** 通道位；数据部分 958,272 bit |
| 布局算术 | `32 × 2052 = 65,664 = 304 × 216`（正好铺满 LDC 的 304 码字 × 216 数据字节） |
| ECC | LDC = RS(248,216) × 304；BIS = RS(9,5) + RS(62,30)；EDC 4 字节；校验子为零 |
| 调制 | 17PP = RLL(1,7)；28 个 DC 控制位贪心选择 |
| 灰阶 | 暗 `0xAA`（偏 3T）/ 亮 `0x44`（偏 6T），可反转；整簇统计 3T = 265,136、6T = 116,575 |
| UDF | UDF 2.01；最小 640 扇区且 %32；> 4 GiB 文件按 `0x3ffff800` 拆 64 位 extent |
| sidecar | `bd-r-image-v1` JSON 往返（扇区、半径、绘图起止、极性、影调、UDF 时间戳） |
| ⚠️ 注意 | 3T/6T 的定灰数字来自**编码结果统计**，不是实测光学极性。蓝光首版为实验性。 |

### 2.5 刻录层（`DiscImageBurningTests`）

刻录层不产生盘片，所以只断言「命令」与「解析」两件事，全部是纯函数/假执行器：

| 不变量 | 断言 |
|---|---|
| 命令序 | `drutil list` = `["list"]`；`drutil -drive 2 status`；`drutil -drive 1 eject` |
| **`-drive` 位置** | 必须出现在动词（`status` / `burn` / `eject`）**之前**（drutil(1) 硬约定） |
| 音频命令 | `drutil -drive 1 burn -audio -noverify <track.wav>`；`.cue` 走镜像路径，不加 `-audio` |
| 数据命令 | `drutil -drive 1 burn -noverify <image.iso>`；hdiutil 用 `hdiutil burn -noverifyburn <image>` |
| 空盘/验盘选项 | `verify=true` 时不加 `-noverify`；`eject=false` 时加 `-noeject`（hdiutil 为 `-noeject`） |
| 设备标识 | `-drive` 只接受正整数；hdiutil 不接受 drutil 序号（抛 `invalidDeviceID`） |
| `drutil list` 解析 | 只有表头（本机真实输出）→ 空数组；两台设备按表头列宽切片（产品名里的双空格保留）；行首多一列序号时退回空白切分 |
| `drutil status` 解析 | 空白 CD-R；折行的 DVD+R DL；非空白 DVD-R（`Writable=false`）；`No Media Inserted` → `noMedia`；空输出 → `noDevice`；解析不出字段 → **报错而不是猜** |
| 容量解析 | `blocks: N` 优先（2048 字节/块），其次 `8.55GB` / `702.82MiB` 等人类可读单位 |
| 进度解析 | `Burning: 42.0% complete` → 写入 42%；`Verifying: 100%` → 校验；`Finalizing` → 收尾；噪音行忽略 |
| 错误分类 | `Could not find a valid device` → 无设备；`No Media Inserted` → 无盘；`not blank` → 非空白盘；`Permission denied` → 权限；`Not enough space` → 容量；其余 → `toolFailed`（带命令 + 退出码 + 输出尾部） |
| 预检 | 非空白盘 / 容量不足时**不会**产生 `burn` 命令（不允许烧到一半才失败） |
| 取消 | 刻录中被取消 → `cancelled(discMayBeDamaged: true)`；预检阶段被取消 → `cancelled(discMayBeDamaged: false)` |
| 多设备 | 不指定设备且 >1 台 → `ambiguousDevices`；此时不会对「所有光驱」执行命令 |

> 测试里用的 `drutil` 输出样本：无设备形态取自本机真实输出；其余按 `drutil(1)` 的栏目名与公开记录（论坛/man page 示例）构造。**样本不是真机抓包**，见 §4。

### 2.6 UI（`DiscImageUITests`）

没有像素基线。回归手段是 `ImageRenderer` 离屏渲染主页与设计页到 PNG：能渲染、不崩、关键控件可达。UI 测试不启动刻录，刻录页用 `MockBurnService` 走状态机。

---

## 3. 用系统工具做的「真实解析」验证

编码链算得再对，容器写错也白搭。下面这些是**用 macOS 自带工具**做的验证（手动执行，输出贴进 PR 或 issue）：

### 3.1 ISO / UDF 挂载

```bash
swift run discimage-cli generate --family dvd --image in.png --out artifacts/dvd.iso
hdiutil attach artifacts/dvd.iso            # 期望：出现 /Volumes/<卷标>
ls -la /Volumes/<卷标>                       # 期望：文件与内外圈放置一致
hdiutil detach /Volumes/<卷标>
```

- DVD：`hdiutil attach` 后能列目录、能读出文件内容；Joliet 中文名正常。
- 蓝光：`hdiutil attach` 后同样能列出 UDF 2.01 卷；超过 4 GiB 的文件按 extent 拆分后仍可读。
- CD 数据盘：ISO9660 Mode 1 映像按同样方式挂载。

### 3.2 WAV / CUE 结构

```bash
swift run discimage-cli generate --family cd --image in.png --format wav --out artifacts/cover.wav
xxd -l 44 artifacts/cover.wav                 # 期望：RIFF / WAVE / fmt / data，44 字节头
cat artifacts/cover.cue                       # 期望：FILE "cover.wav" WAVE + TRACK 01 AUDIO
afinfo artifacts/cover.wav                    # 期望：44.1 kHz / 16 bit / 2 ch
```

### 3.3 命令行退出码

`discimage-cli` 对每个参数错误都应以非 0 退出并打印中文原因（未知介质、预设与 `--family` 不符、CD 的 ISO 输出缺少 `--data-dir`、几何校验失败等）。

---

## 4. 明确无法验证的部分

**这一节是本文最重要的部分。** 以下项目在本机与 CI 上都无法验证，任何「已验证」的说法都不能覆盖它们：

1. **真实烧录**：没有刻录机。`drutil burn` / `hdiutil burn` 从未被真正执行过。`BurnService` 只验证到命令构造、输出解析、错误翻译、取消措辞。
2. **实盘光学极性 / 反射亮度**：盘面上的「黑」与「白」最终由染料/相变层的反射率决定，不由编码决定。DVD 的 `0xA5`/`0x92` 是源项目按实盘结果反推的；蓝光的 3T/6T 是数字编码统计，**从未实拍验证**。首版蓝光功能按实验性对待。
3. **图案在真盘上的对齐**：`drutil` 不保证 DAO 的字节级控制，可能插入间隙/边距，导致图案整体旋转或偏移；这属于刻录器行为，无法在无硬件环境验证。
4. **盘片容量与真实介质一致性**：`drutil status` 报的容量随盘片与固件变化；预检只是把明显的「容量不足」提前拦下，不代表磁盘一定写得下。
5. **光驱/固件差异**：不同品牌、不同固件对 `-audio`、`-noverify`、`-speed` 的接受程度不同；`drutil` 又有「invalid commands are ignored」的行为，可能要上真机才发现某个选项被静默忽略。
6. **`drutil` / `hdiutil` 输出格式的版本差异**：解析器是按公开文档与固定样本写的容错实现，没有在多个 macOS 版本 × 多种盘片上回归。解析失败时会报 `unparsableStatus` 并附原始输出，而不是猜。
7. **CD 图案质量**：源项目只有一次「无重影」反馈；本移植没有 CIRC/EFM，重影/抖动表现未经验证。
8. **性能**：没有做吞吐/耗时基准；BD 25 GB 的生成时间只按经验估计。
9. **标定流程**（三次轨距、拍盘反解）**未做实盘验证**：预设参数来自上游，本机没有标定照片。

**后续实盘记录应包含**：版本或提交 hash、刻录机型号与固件、盘片品牌/型号、所用盘片预设、写入速度、生成入口（GUI/CLI + 参数）、刻录入口（应用内 / 手动 `drutil`）、原始照片（含对比基线）。没有这些信息的「看起来正常」不能作为泛化结论。

---

## 5. 验证记录（本移植首版）

- 编码层：`DiscImageCoreTests` / `DiscImageDvdTests` / `DiscImageCdTests` / `DiscImageBluRayTests` 为纯 Swift 单元测试，跑在 `swift test` 里；不依赖光驱、不依赖网络。
- 刻录层：`DiscImageBurningTests` 当前 60 个用例（以 `swift test` 实际输出为准），覆盖命令构造、输出解析、错误分类、预检、取消、Mock 行为；全部使用假执行器，**没有任何测试调用 `drutil` / `hdiutil`**。
- CI：`.github/workflows/ci.yml` 在 `macos-latest` 上跑 `swift build` + `swift test`；CI 机器没有刻录机，因此 CI 通过 **不代表** 烧录可用。
- 本机实测记录：`drutil list` 在无光驱时只打印表头（已作为解析回归样本）；`drutil status` 无光驱时输出为空且退出码 0；`drutil -drive 1 status` 退出码 1、stderr 为 `Could not find a valid device.`。
