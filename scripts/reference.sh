#!/bin/bash
# 生成「逐字节不变」回归用的参考产物，并验证串行/并行两条路径完全一致。
#
# 用法：
#   scripts/reference.sh              # 生成到 artifacts/reference 并打印 sha256
#   scripts/reference.sh --check      # 只校验现有参考产物（不覆盖）
#
# 为什么能复现：DVD 的 ISO9660 PVD/SVD 与目录记录带 wall-clock 时间戳，
# 1024 扇区的输出里有 32 字节随生成时刻变化（payload 完全一致）。
# 引擎支持 SOURCE_DATE_EPOCH（Unix 秒，可带小数）钉住这些时间戳，
# 所以这里固定成 1700000000 就能得到稳定 sha256。
set -euo pipefail
cd "$(dirname "$0")/.."

SCRATCH="${SCRATCH:-.build}"
CLI="$SCRATCH/release/discimage-cli"
REFERENCE="artifacts/reference"
IMAGE="artifacts/gradient.png"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1700000000}"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

[ -x "$CLI" ] || { echo "✗ 找不到 $CLI，先运行：scripts/build.sh -c release --product discimage-cli" >&2; exit 1; }
[ -f "$IMAGE" ] || { echo "✗ 缺少测试图 $IMAGE（scripts/verify.sh 会生成它）" >&2; exit 1; }

mkdir -p "$REFERENCE"
WORK=$(mktemp -d "$REFERENCE/.work-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

fail=0
generate() { # <name> <family> <args...>
    local name="$1"; shift
    local family="$1"; shift
    local target="$REFERENCE/$name"
    local first="$WORK/$name.serial"
    local second="$WORK/$name.parallel"

    if [ "$CHECK_ONLY" -eq 1 ]; then
        [ -f "$target" ] || { echo "✗ 缺少参考产物 $target" >&2; fail=$((fail + 1)); return; }
    fi

    DISCI_MAX_WORKERS=1 "$CLI" generate --family "$family" "$@" --quiet --out "$first" >/dev/null
    DISCI_MAX_WORKERS=8 "$CLI" generate --family "$family" "$@" --quiet --out "$second" >/dev/null
    if ! cmp -s "$first" "$second"; then
        echo "✗ $name：串行与并行输出不一致" >&2
        fail=$((fail + 1))
        return
    fi

    if [ "$CHECK_ONLY" -eq 1 ]; then
        if ! cmp -s "$first" "$target"; then
            echo "✗ $name：与 $target 不一致（回归失败）" >&2
            fail=$((fail + 1))
            return
        fi
    else
        cp "$first" "$target"
    fi
    printf '✓ %-22s %s\n' "$name" "$(shasum -a 256 "$target" | cut -d' ' -f1)"
}

generate dvd1024.iso  dvd --inner 24 --outer 40 --sectors 1024 --image "$IMAGE"
generate dvd8k.iso   dvd --inner 24 --outer 50 --sectors 8192 --image "$IMAGE"
generate bd1024.iso  bd  --inner 24 --outer 40 --sectors 1024 --image "$IMAGE"
generate cd6000.wav  cd  --inner 24.5 --outer 32 --sectors 6000 --image "$IMAGE" --format wav

# CD 会旁写 .cue；一起纳入参考
if [ -f "$WORK/cd6000.wav.serial.cue" ]; then :; fi

if [ "$CHECK_ONLY" -eq 0 ]; then
    ( cd "$REFERENCE" && shasum -a 256 *.iso *.wav *.cue 2>/dev/null > SHA256SUMS )
    echo
    echo "参考产物已写入 $REFERENCE/，sha256 清单见 SHA256SUMS"
else
    echo
    echo "校验完成：$([ "$fail" -eq 0 ] && echo 全部一致 || echo "有 $fail 项不一致")"
fi

exit $((fail > 0))
