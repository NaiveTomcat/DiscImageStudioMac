#!/bin/bash
# 打包成可分发的 macOS 应用：release 构建 → .app bundle → 签名 → DMG → 公证 → 装订票据。
#
# 用法：
#   scripts/package.sh                  # 默认：构建 + 签名 + DMG + 公证
#   scripts/package.sh --skip-notarize  # 没有公证凭据时，只做到签名 + DMG
#   scripts/package.sh --no-dmg         # 只出 .app（不打 DMG）
#   scripts/package.sh --open           # 结束后打开 dist 目录
#
# 环境变量（都可覆盖）：
#   IDENTITY        签名身份，默认脚本里那条 Developer ID Application
#   BUNDLE_ID       Bundle Identifier，默认 com.yitongdang.discimagestudio
#   VERSION         版本号，默认从 Sources/DiscImageCore/Version.swift 读
#   BUILD_NUMBER    CFBundleVersion，默认时间戳
#   NOTARY_PROFILE  notarytool keychain profile 名，默认 discimagestudio
#   NOTARY_KEY / NOTARY_KEY_ID / NOTARY_ISSUER
#                   用 App Store Connect API Key 公证时给出（三者都要）
#   SCRATCH / JOBS  透传给 SwiftPM 构建
#
# 公证凭据只需要准备一次，见 docs/RELEASING.md 第 2 节。
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="DiscImageStudio"
DISPLAY_NAME="Disc Image Studio"
BUNDLE_ID="${BUNDLE_ID:-com.yitongdang.discimagestudio}"
IDENTITY="${IDENTITY:-Developer ID Application: Yitong Dang (BTQCLGS649)}"
TEAM_ID="${TEAM_ID:-BTQCLGS649}"
# 公证 profile：显式给 NOTARY_PROFILE 就用它；否则依次探测这些已存在钥匙串 profile。
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_PROFILE_CANDIDATES=("discimagestudio" "readmoo-notary")
DIST="${DIST:-dist}"
SCRATCH="${SCRATCH:-.build}"
JOBS="${JOBS:-2}"

VERSION="${VERSION:-$(sed -n 's/.*public static let version = "\([^"]*\)".*/\1/p' Sources/DiscImageCore/Version.swift | head -1)}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"

DO_DMG=1
DO_NOTARIZE=1
OPEN_AFTER=0
for argument in "$@"; do
    case "$argument" in
        --skip-notarize) DO_NOTARIZE=0 ;;
        --no-dmg) DO_DMG=0 ;;
        --open) OPEN_AFTER=1 ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：${argument}（试 --help）" >&2; exit 2 ;;
    esac
done

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
note() { printf '   %s\n' "$1"; }

APP="$DIST/stage/$APP_NAME.app"
DMG="$DIST/$APP_NAME-$VERSION.dmg"

step "0/6 环境检查"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✗ 找不到签名身份：$IDENTITY" >&2
    echo "  现有身份：" >&2
    security find-identity -v -p codesigning 2>/dev/null | sed 's/^/    /' >&2
    exit 1
fi
note "签名身份：$IDENTITY"
note "版本：${VERSION}（build ${BUILD_NUMBER}）"
note "Bundle ID：$BUNDLE_ID"
rm -rf "$DIST/stage" "$DIST/dmg-root"
mkdir -p "$DIST"

step "1/6 release 构建"
SCRATCH="$SCRATCH" JOBS="$JOBS" scripts/build.sh -c release --product "$APP_NAME"
BINARY="$SCRATCH/release/$APP_NAME"
[ -x "$BINARY" ] || { echo "✗ 找不到构建产物：$BINARY" >&2; exit 1; }
note "二进制：$(du -h "$BINARY" | cut -f1)"

step "2/6 组装 .app bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.graphics-design</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
    <key>NSSupportsSuddenTermination</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>GPL-3.0-or-later · 基于 Disc Image Studio（Windows 版）移植</string>
</dict>
</plist>
PLIST

python3 scripts/make-icon.py "$DIST/icon" >/dev/null
cp "$DIST/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
note "图标：$(du -h "$APP/Contents/Resources/AppIcon.icns" | cut -f1)"

step "3/6 代码签名（hardened runtime + 安全时间戳）"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" \
    --options runtime --timestamp --generate-entitlement-der "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Identifier=|TeamIdentifier=|Authority=|Runtime Version" | sed 's/^/   /'
note "签名校验通过"

step "4/6 打 DMG"
if [ "$DO_DMG" -eq 1 ]; then
    mkdir -p "$DIST/dmg-root"
    cp -R "$APP" "$DIST/dmg-root/"
    ln -s /Applications "$DIST/dmg-root/Applications"
    rm -f "$DMG"
    # 注意：`hdiutil create -srcfolder` 需要临时挂载一个可写卷，在受限沙箱里会
    # 直接报 "Operation not permitted"。改用 makehybrid（纯文件操作、不挂载）
    # 先生成 HFS+ 镜像，再 convert 成压缩的 UDZO。
    RAW_DMG="$DIST/.$APP_NAME-raw.dmg"
    rm -f "$RAW_DMG"
    hdiutil makehybrid -quiet -o "$RAW_DMG" "$DIST/dmg-root" \
        -hfs -hfs-volume-name "$DISPLAY_NAME"
    hdiutil convert "$RAW_DMG" -quiet -format UDZO -o "$DMG"
    rm -f "$RAW_DMG"
    # DMG 本身也要签名，否则 Gatekeeper 在打开镜像时给不出可信来源
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
    codesign --verify --verbose=2 "$DMG"
    note "DMG：${DMG}（$(du -h "$DMG" | cut -f1)）"
else
    note "已跳过 DMG（--no-dmg）"
fi

resolve_notary_profile() {
    if [ -n "$NOTARY_PROFILE" ]; then
        printf '%s\n' "$NOTARY_PROFILE"
        return 0
    fi
    local candidate
    for candidate in "${NOTARY_PROFILE_CANDIDATES[@]}"; do
        if xcrun notarytool history --keychain-profile "$candidate" >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# 提交公证。用函数而不是 mapfile：macOS 自带的 /bin/bash 是 3.2，没有 mapfile。
notary_submit() {
    local target="$1"
    if [ -n "${NOTARY_KEY:-}" ]; then
        local args=(--key "$NOTARY_KEY")
        [ -n "${NOTARY_KEY_ID:-}" ] && args+=(--key-id "$NOTARY_KEY_ID")
        [ -n "${NOTARY_ISSUER:-}" ] && args+=(--issuer "$NOTARY_ISSUER")
        xcrun notarytool submit "$target" "${args[@]}" --wait
    else
        xcrun notarytool submit "$target" --keychain-profile "$(resolve_notary_profile)" --wait
    fi
}

step "5/6 公证"
if [ "$DO_NOTARIZE" -eq 0 ]; then
    note "已跳过公证（--skip-notarize）；这份产物在别人的机器上会被 Gatekeeper 拦"
elif [ "$DO_DMG" -eq 0 ]; then
    note "没有 DMG 时公证需要 --no-dmg 之外的目标；这里提交 .app 的 zip"
    mkdir -p "$DIST"
    ditto -c -k --keepParent "$APP" "$DIST/$APP_NAME-$VERSION.zip"
    TARGET="$DIST/$APP_NAME-$VERSION.zip"
    notary_submit "$TARGET"
    xcrun stapler staple "$APP"
else
    if [ -z "${NOTARY_KEY:-}" ] && ! resolve_notary_profile >/dev/null; then
        cat >&2 <<'EOF'
✗ 没有可用的公证凭据（钥匙串里没有 discimagestudio / readmoo-notary profile，也没有 NOTARY_KEY）。
  配置一次：scripts/setup-notary.sh
  或者先拿本地产物：scripts/package.sh --skip-notarize
EOF
        exit 3
    fi
    note "公证 profile：$(resolve_notary_profile 2>/dev/null || echo '<API Key>')"
    if ! notary_submit "$DMG"; then
        cat >&2 <<'EOF'

✗ 公证提交失败。
  如果没有配置凭据，先准备一次（只需要一次）：
      xcrun notarytool store-credentials "discimagestudio" \
          --apple-id "你的 Apple ID" \
          --team-id "BTQCLGS649" \
          --password "App 专用密码"
  或改用 App Store Connect API Key：
      NOTARY_KEY=~/keys/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX \
      NOTARY_ISSUER=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx scripts/package.sh
  没有凭据又想先拿到可本地运行的产物：scripts/package.sh --skip-notarize
EOF
        exit 3
    fi
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
fi

step "6/6 Gatekeeper 验收"
if [ -f "$DMG" ]; then
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" && \
        note "DMG 通过 Gatekeeper 评估（已公证）" || \
        note "DMG 未通过 Gatekeeper 评估（未公证时属预期）"
fi
spctl --assess --type execute --verbose=2 "$APP" && \
    note ".app 通过 Gatekeeper 评估" || \
    note ".app 未通过 Gatekeeper 评估（未公证时属预期）"

printf '\n\033[32m打包完成\033[0m\n'
note ".app ：$APP"
[ -f "$DMG" ] && note "DMG  ：$DMG"
note "版本 ：${VERSION}（${BUILD_NUMBER}）"

if [ "$OPEN_AFTER" -eq 1 ]; then
    open "$DIST"
fi
