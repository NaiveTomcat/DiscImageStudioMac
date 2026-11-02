# Changelog

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)；预发布版本在版本号后带 `-rc` 或直接标记为
GitHub Pre-release。

## [0.1.0] — 2026-11-02 — 首个预发布

macOS 原生移植版的第一版。**面向「等实盘验证」的预发布**：编码链路、文件系统与打包公证都可复现，
但**没有任何一次真实烧录**（开发机没有刻录机，也没有空白光盘）。

### 新增

- **三种介质的编码引擎**
  - **DVD**：扰码 / ECC（PI+PO，含增量重建）/ EFMPlus（双 Stream DSV 选择 + SYNC 主副码替换）/
    NRZI / 16 扇区 ECC Block 组装；快速纹理映射路径（payload 字节只在 `0xA5`/`0x92` 中选）。
  - **CD**：几何与面积线性采样、2 阶（`0x0D`/`0xAA`）与 4 阶（`0x0D`/`0x10`/`0x63`/`0xAA`）灰阶、
    112 帧环形延迟交织（offset 72…2592，尾部丢弃 1332 字节）、WAV（小端 + 44 字节 RIFF）/ RAW（大端）/ 数据盘 Mode 1。
  - **蓝光**：EDC、LDC RS(248,216)×304、BIS RS(9,5)+RS(62,30)、17PP（RLL(1,7)）、28 位 DC 控制、
    RUB 组装、3T/6T 定灰（`0xAA`/`0x44`，可反极性）、UDF 2.01。
- **文件系统**：ISO9660（主卷 + Joliet SVD + 路径表，内外圈放置、Unicode 名、拒绝符号链接、单文件 ≤ 4 GiB−1）、UDF 2.01（≥640 扇区且 %32、>4 GiB 按 `0x3ffff800` 拆 extent）、BD sidecar JSON。
- **SwiftUI 应用**：主页 / 设计（mm 画布、影调面板）/ 预览（极坐标盘面、文件区高亮）/
  导出 / 刻录（设备→空白检查→倍速→二次确认）/ 标定；`.discproj` 工程文件（schemaVersion 2，兼容 schema 1）。
- **刻录封装**：`drutil` / `hdiutil` 的命令构造与输出解析（纯函数、可单测）、取消与超时、中文错误文案。
- **CLI**：`discimage-cli generate / presets / geometry / info`。
- **工程化**：349 个单元测试、`scripts/verify.sh` 端到端验收、`scripts/package.sh` 签名+公证、
  `scripts/reference.sh` 逐字节回归、CI（macOS）。

### 性能（release，Apple M5，默认并行）

| 介质 | 整盘规模 | 耗时 |
|---|---|---|
| DVD-5 | 2,295,104 扇区 / 4.4 GB | 34 s |
| CD 80min | 359,849 扇区 / 845 MB | 9.7 s |
| BD-R SL | 12,219,392 扇区 / 25 GB | 66 s（纯计算） |

并行化不改变任何一个输出字节（`scripts/reference.sh --check` 会验证串行与 8 线程输出一致）。

### 已验证

- `swift build` / `swift test` 全绿；`scripts/verify.sh` 全过。
- 生成的 DVD ISO9660 与蓝光 UDF 镜像均能被 `hdiutil attach` 挂载，文件内容 `cmp` 逐字节一致。
- 应用已用 Developer ID 签名、公证并装订；Gatekeeper 评估通过（含带隔离属性启动）。

### 未验证 / 已知限制

- **真实烧录从未执行**；刻录链路只验证到命令构造、输出解析、错误翻译与取消措辞。
- **实盘光学极性**未知：DVD 的 `0xA5`/`0x92`、蓝光的 3T/6T 都是编码约定，不是实测反射率。
- `drutil` 不保证 DAO 字节级控制，图案在真盘上可能整体旋转/偏移。
- 仅 **arm64**（Apple Silicon）；未构建 Universal Binary。
- DVD **不含** beam search 约束求解器（只有快速纹理映射，与上游 GUI 一致）。
- CD **没有** CIRC 与 EFM（上游本身也没有，只做字节级延迟重排）。
- 蓝光为实验性：整盘 25 GB 未实跑，性能为线性外推。
- GUI 的 8192 px 合成图导出在主线程同步执行，会卡几秒；预览页「成品读回」暂未接引擎真实读回。

### 下一步

拿到刻录机与 DVD-R 后按 `docs/VALIDATION.md` §4 的清单做实盘记录（版本 hash、刻录机型号固件、
盘片型号、所用预设、写入速度、生成/刻录入口、原始照片），再决定是否把预设与极性写回默认值。
