#!/bin/bash
# 一次性配置公证凭据（存进钥匙串，之后 package.sh 直接复用）。
#
# 为什么不能全自动：Apple 只接受「App 专用密码」或「App Store Connect API Key」，
# 两者都必须先在网页上生成，命令行无法凭空造出来，也没法从 Xcode 的登录态导出。
#
# 用法：
#   scripts/setup-notary.sh                 # 交互式：问你 Apple ID 和专用密码
#   scripts/setup-notary.sh --profile dev   # 换一个 profile 名
#   scripts/setup-notary.sh --api-key ~/keys/AuthKey_ABC123.p8 \
#       --key-id ABC123 --issuer 69a6de7e-... # 用 API Key 方式
#
# 生成 App 专用密码（约 30 秒）：
#   1. 打开 https://account.apple.com/account/manage
#   2. 登录后进「登录与安全」→「App 专用密码」→「+」
#   3. 名字随便写（例如 DiscImageStudio notarization），复制生成的 xxxx-xxxx-xxxx-xxxx
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="discimagestudio"
TEAM_ID="${TEAM_ID:-BTQCLGS649}"
MODE="password"
API_KEY=""
KEY_ID=""
ISSUER=""

while [ $# -gt 0 ]; do
    case "$1" in
        --profile) PROFILE="$2"; shift 2 ;;
        --team-id) TEAM_ID="$2"; shift 2 ;;
        --api-key) MODE="api"; API_KEY="$2"; shift 2 ;;
        --key-id) KEY_ID="$2"; shift 2 ;;
        --issuer) ISSUER="$2"; shift 2 ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
done

echo "== 配置公证凭据（profile: ${PROFILE}，team: ${TEAM_ID}） =="

if [ "$MODE" = "api" ]; then
    [ -f "$API_KEY" ] || { echo "✗ 找不到 API Key 文件：$API_KEY" >&2; exit 1; }
    [ -n "$KEY_ID" ] && [ -n "$ISSUER" ] || { echo "✗ 用 API Key 时 --key-id 与 --issuer 都必填" >&2; exit 1; }
    xcrun notarytool store-credentials "$PROFILE" \
        --key "$API_KEY" --key-id "$KEY_ID" --issuer "$ISSUER"
else
    printf 'Apple ID（邮箱）：'
    read -r APPLE_ID
    [ -n "$APPLE_ID" ] || { echo "✗ Apple ID 不能为空" >&2; exit 1; }
    printf 'App 专用密码（xxxx-xxxx-xxxx-xxxx，输入时不回显）：'
    read -r -s APP_PASSWORD
    printf '\n'
    [ -n "$APP_PASSWORD" ] || { echo "✗ 密码不能为空" >&2; exit 1; }
    xcrun notarytool store-credentials "$PROFILE" \
        --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD"
fi

echo
echo "== 校验凭据 =="
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null && \
    echo "✓ 凭据可用（profile: ${PROFILE}）" || {
        echo "✗ 凭据不可用，检查 Apple ID / 专用密码 / Team ID 是否正确" >&2
        exit 1
    }

cat <<EOF

下一步：
    scripts/package.sh              # 构建 + 签名 + DMG + 公证 + 装订
EOF
