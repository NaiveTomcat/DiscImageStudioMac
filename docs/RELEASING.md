# 发布与分发

> 目标产物：`dist/DiscImageStudio-<版本>.dmg` —— 已签名（Developer ID + hardened runtime + 时间戳）、已公证、已装订票据，双击即可在别人的 Mac 上打开。

## 0. 一条命令

```bash
scripts/package.sh            # 构建 + 签名 + DMG + 公证 + 装订 + Gatekeeper 验收
scripts/package.sh --skip-notarize   # 没配凭据时：只出签名好的 .app + DMG
scripts/package.sh --no-dmg   # 只要 .app（公证时会自动打成 zip 提交）
scripts/package.sh --open     # 结束打开 dist/
```

产物：

```
dist/stage/DiscImageStudio.app          已签名、带图标、带 Info.plist
dist/DiscImageStudio-0.1.0.dmg          已签名 + 已公证 + 已装订
dist/AppIcon.icns                       程序化生成的图标
```

脚本里的签名身份默认是 `Developer ID Application: Yitong Dang (BTQCLGS649)`，
可用 `IDENTITY=...` 覆盖；`BUNDLE_ID` / `VERSION` / `BUILD_NUMBER` 同理。

## 1. 前置：一张 Developer ID 证书

```bash
security find-identity -v -p codesigning
# 期望看到： "Developer ID Application: <名字> (TEAMID)"
```

没有的话：Xcode → Settings → Accounts → 选中团队 → Manage Certificates → **+** → Developer ID Application。

## 2. 公证凭据（**只能人工生成一次**）

Apple 不接受「用 Xcode 的登录态直接公证」——Xcode 只保留 Apple ID 的账号标识（UUID），
不导出任何可被 `notarytool` 使用的凭据。`notarytool` 只认下面两种凭据，
而且两者都只能在网页上生成，命令行无法代劳。**如果你之前已经为别的项目配过
keychain profile，直接复用即可**（见 2.3）。

### 方式 A：App 专用密码（最省事）

1. 打开 <https://account.apple.com/account/manage> 登录
2. 「登录与安全」→「App 专用密码」→ **+**，名字写 `DiscImageStudio notarization`
3. 复制形如 `abcd-efgh-ijkl-mnop` 的密码
4. 存进钥匙串（**只需一次**）：

```bash
scripts/setup-notary.sh
# 或者手动：
xcrun notarytool store-credentials "discimagestudio" \
    --apple-id "你的 Apple ID" --team-id "BTQCLGS649" \
    --password "abcd-efgh-ijkl-mnop"
```

### 方式 B：App Store Connect API Key

App Store Connect → 用户和访问 → 集成 → App Store Connect API → 生成 Team Key（下载 `.p8`，**只能下载一次**）。

```bash
scripts/setup-notary.sh --api-key ~/keys/AuthKey_ABC123.p8 \
    --key-id ABC123 --issuer 69a6de7e-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

也可以不落钥匙串，直接给 `package.sh` 传环境变量：

```bash
NOTARY_KEY=~/keys/AuthKey_ABC123.p8 NOTARY_KEY_ID=ABC123 \
NOTARY_ISSUER=69a6de7e-... scripts/package.sh
```

验证凭据：

```bash
xcrun notarytool history --keychain-profile discimagestudio
```

### 2.3 复用已有的 keychain profile

`package.sh` 在没有显式给 `NOTARY_PROFILE` 时会依次探测：

```
discimagestudio → readmoo-notary
```

只要其中任何一个 `notarytool history` 能跑通就用它。显式指定：

```bash
NOTARY_PROFILE=readmoo-notary scripts/package.sh
```

> 本机（2026-11-02）实际使用的是 `readmoo-notary`——它与本项目的签名证书同属
> 团队 `BTQCLGS649`，因此可以直接给本项目公证。

## 3. 脚本做了什么

| 步骤 | 细节 |
|---|---|
| release 构建 | `swift build -c release --product DiscImageStudio`（`--jobs 2`，避免打满 CPU） |
| 组装 bundle | `Contents/MacOS/DiscImageStudio` + `Info.plist` + `Resources/AppIcon.icns` + `PkgInfo` |
| 图标 | `scripts/make-icon.py` 程序化绘制（numpy + Pillow），无外部素材 |
| 签名 | `codesign --force --options runtime --timestamp --identifier <bundle id>` |
| DMG | 先 `hdiutil makehybrid -hfs` 再 `hdiutil convert -format UDZO`，内含 `/Applications` 软链；DMG 本身也签名 |
| 公证 | `xcrun notarytool submit <dmg> --wait`（凭据缺失时给出明确指引并退出 3） |
| 装订 | `xcrun stapler staple` + `stapler validate` |
| 验收 | `codesign --verify --strict`、`spctl --assess --type open/execute` |

## 3.1 两个实现上的坑（已踩过）

1. **`hdiutil create -srcfolder` 在受限沙箱里会 `Operation not permitted`**：它会临时挂载
   一个可写卷来拷文件，而构建环境（以及 CI 的沙箱）不允许。改成
   `hdiutil makehybrid`（纯文件操作）→ `hdiutil convert -format UDZO` 两步，产物等价。
2. **`mapfile` 不可用**：`#!/bin/bash` 在 macOS 上是 3.2，没有 bash 4 的 `mapfile`/关联数组。
   脚本里的公证参数用函数 + 数组构造，别写 bash 4 语法。

## 4. 为什么不是 Xcode Archive

这个仓库是纯 SwiftPM 包（没有 `.xcodeproj`），产物是 `@main` 的 SwiftUI 可执行文件。
Xcode 的 Archive → Distribute 流程面向 `.xcodeproj` 的 app target，
对 SwiftPM executable 不生成可归档的 `.app`，所以这里用脚本组装 bundle —— 这也是
Sparkle、tuist 等工具常见的做法。bundle 的字段与 Xcode 生成的等价（见脚本里的 `Info.plist`）。

## 5. 版本号

单一来源：`Sources/DiscImageCore/Version.swift` 的 `version`。
`package.sh` 会自动读取它；`CFBundleVersion` 默认用 UTC 时间戳，可 `BUILD_NUMBER=42` 覆盖。

## 5.1 本次实际运行记录（2026-11-02）

```
✓ release 构建 37 s，二进制 3.5 MB
✓ 签名：Developer ID Application: Yitong Dang (BTQCLGS649)，hardened runtime 14.0，安全时间戳
✓ DMG：dist/DiscImageStudio-0.1.0.dmg（2.1 MB）
✓ 公证：submission 47a4edc3-6bc8-4a73-9b05-8bcfb39c2fd7 → Accepted
✓ 装订：staple + validate 通过
✓ Gatekeeper：DMG 与 .app 均 "accepted / Notarized Developer ID"
✓ 隔离属性（com.apple.quarantine）下拷贝到 /tmp 再启动：进程常驻、无崩溃
```

## 6. 已知限制

- 公证需要联网（Apple 服务），且要求应用用 Developer ID 证书 + hardened runtime 签名。
- 未公证的 DMG 在别的机器上会被 Gatekeeper 拦截（`--skip-notarize` 只适合本机自测）。
- 当前产物是 arm64（Apple Silicon）单架构；要兼容 Intel 需在脚本里加 `--arch x86_64` 的通用二进制构建（`swift build --arch arm64 --arch x86_64`）。
