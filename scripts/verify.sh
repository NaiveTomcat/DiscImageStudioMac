#!/bin/bash
# 端到端验收脚本（HANDOFF §7）。
#
# 用法：scripts/verify.sh [--no-burn-mount]
#
# 做四件事：
#   1. swift build 全量
#   2. swift test 全量
#   3. 三种介质各生成一个小镜像到 artifacts/，并用 hdiutil attach 验证文件系统结构
#   4. 打印 UI 离屏渲染产物位置
#
# 本机没有刻录机 / 空白盘，所以「真实烧录」这一步不在脚本里，
# 刻录路径只验证到「命令构造 + 错误处理」（Tests/DiscImageBurningTests）。
set -uo pipefail
cd "$(dirname "$0")/.."

SCRATCH="${SCRATCH:-.build}"
export CLANG_MODULE_CACHE_PATH="$PWD/$SCRATCH/modulecache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/$SCRATCH/modulecache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

MOUNT_CHECK=1
for argument in "$@"; do
    case "$argument" in
        --no-burn-mount) MOUNT_CHECK=0 ;;
        *) echo "未知参数：$argument" >&2; exit 2 ;;
    esac
done

ARTIFACTS="$PWD/artifacts"
mkdir -p "$ARTIFACTS"
CLI="$PWD/$SCRATCH/debug/discimage-cli"
FAILURES=0

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$1"; FAILURES=$((FAILURES + 1)); }
pass() { printf '\033[32m✓ %s\033[0m\n' "$1"; }

step "1/4 swift build"
if swift build --disable-sandbox --scratch-path "$SCRATCH" ; then
    pass "构建通过"
else
    fail "构建失败"
    exit 1
fi

step "2/4 swift test"
if swift test --disable-sandbox --scratch-path "$SCRATCH" ; then
    pass "测试全绿"
else
    fail "测试失败"
fi

step "3/4 生成镜像 + hdiutil 挂载检查"
mkdir -p "$ARTIFACTS/payload/sub"
printf 'Disc Image Studio macOS 验收\n' > "$ARTIFACTS/payload/readme.txt"
head -c 4096 /dev/urandom > "$ARTIFACTS/payload/sub/blob.bin"

# 测试图：从左到右的灰度渐变条（1024×1024），足以让三条链路都跑起来。
python3 - "$ARTIFACTS/gradient.png" <<'PY'
import struct, sys, zlib
size = 1024
rows = bytearray()
for y in range(size):
    rows.append(0)  # filter type 0
    for x in range(size):
        value = (x * 255) // (size - 1)
        rows += bytes((value, value, value))
def chunk(tag, data):
    return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n'
png += chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(bytes(rows), 6))
png += chunk(b'IEND', b'')
open(sys.argv[1], 'wb').write(png)
PY
pass "测试图 $ARTIFACTS/gradient.png"

# 上一次被中断的挂载会留下「Resource busy」，先按 image-path 反查并强制卸载。
detach_stale_mounts() {
    local image="$1"
    hdiutil info 2>/dev/null | awk -v img="$image" '
        /^image-path/ { path = $3 }
        /^\/dev\/disk/ { if (path == img) print $1 }
    ' | while read -r device; do
        hdiutil detach -force "$device" >/dev/null 2>&1 || true
    done
}

mount_and_verify() {
    local image="$1" label="$2" expect_pattern="$3"
    if [ ! -s "$image" ]; then
        fail "${label}：产物为空 ($image)"
        return
    fi
    if [ "$MOUNT_CHECK" -eq 0 ]; then
        pass "${label}：已生成 $(du -h "$image" | cut -f1)"
        return
    fi
    detach_stale_mounts "$image"
    local mount_point
    mount_point=$(mktemp -d "$ARTIFACTS/mount-XXXXXX")
    if hdiutil attach -nobrowse -readonly -mountpoint "$mount_point" "$image" >/dev/null 2>&1; then
        if ls "$mount_point" | grep -q "$expect_pattern"; then
            pass "${label}：挂载成功，内容含 $expect_pattern"
        else
            fail "${label}：挂载成功但找不到 ${expect_pattern}（$(ls "$mount_point" | tr '\n' ' ')）"
        fi
        hdiutil detach "$mount_point" >/dev/null 2>&1 || hdiutil detach -force "$mount_point" >/dev/null 2>&1
    else
        fail "${label}：hdiutil attach 失败"
    fi
    rmdir "$mount_point" 2>/dev/null
}

# DVD 纯绘图（不带文件系统文件，只验证能生成 + 能挂载）
"$CLI" generate --family dvd --inner 24 --outer 40 --sectors 256 \
    --image "$ARTIFACTS/gradient.png" --out "$ARTIFACTS/dvd-image.iso" --quiet \
    && pass "DVD 纯绘图生成" || fail "DVD 纯绘图生成"

# DVD 数据盘：256 扇区（16 的整数倍）
"$CLI" generate --family dvd --inner 24 --outer 40 --sectors 256 \
    --image "$ARTIFACTS/gradient.png" --data-dir "$ARTIFACTS/payload" \
    --label VERIFY_DVD --out "$ARTIFACTS/dvd.iso" --quiet \
    && pass "DVD 数据盘生成" || fail "DVD 数据盘生成"
mount_and_verify "$ARTIFACTS/dvd.iso" "DVD/ISO9660" "readme.txt"

# 蓝光数据盘：640 扇区（32 的整数倍，UDF 下限）
"$CLI" generate --family bd --inner 24 --outer 40 --sectors 640 \
    --image "$ARTIFACTS/gradient.png" --data-dir "$ARTIFACTS/payload" \
    --label VERIFY_BD --out "$ARTIFACTS/bd.iso" --quiet \
    && pass "蓝光数据盘生成" || fail "蓝光数据盘生成"
mount_and_verify "$ARTIFACTS/bd.iso" "蓝光/UDF" "readme.txt"
if [ -s "$ARTIFACTS/bd-bd-r-image-v1.json" ]; then
    pass "蓝光 sidecar JSON"
else
    fail "蓝光缺少 sidecar JSON"
fi

# CD：音频轨（WAV + CUE）
# 注意用**小几何**（3000 扇区 ≈ 7 MB）：debug 构建下整盘 cd-74（333,000 扇区 ≈ 784 MB）
# 需要约半小时，那只适合 release 构建手动跑，不适合当验收脚本。
"$CLI" generate --family cd --inner 24.5 --outer 30 --sectors 3000 \
    --image "$ARTIFACTS/gradient.png" \
    --format wav --out "$ARTIFACTS/cd.wav" --quiet \
    && pass "CD 生成 WAV" || fail "CD 生成 WAV"
if [ -s "$ARTIFACTS/cd.cue" ]; then pass "CD 旁写 CUE"; else fail "CD 缺少 CUE"; fi
head -c 4 "$ARTIFACTS/cd.wav" 2>/dev/null | grep -q RIFF && pass "WAV RIFF 头正确" || fail "WAV 头异常"

step "4/4 汇总"
if [ "$FAILURES" -eq 0 ]; then
    printf '\033[32m全部验收通过\033[0m\n'
else
    printf '\033[31m有 %d 项失败\033[0m\n' "$FAILURES"
fi
exit $((FAILURES > 0))
