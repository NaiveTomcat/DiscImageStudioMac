#!/bin/bash
# 统一的测试入口，参数原样传给 swift test（例如 --filter DiscImageDvdTests）。
set -euo pipefail
cd "$(dirname "$0")/.."
SCRATCH="${SCRATCH:-.build}"
JOBS="${JOBS:-2}"
export CLANG_MODULE_CACHE_PATH="$PWD/$SCRATCH/modulecache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/$SCRATCH/modulecache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
echo "+ swift test --jobs $JOBS --disable-sandbox --scratch-path $SCRATCH $*" >&2
exec swift test --jobs "$JOBS" --disable-sandbox --scratch-path "$SCRATCH" "$@"
