#!/bin/bash
# 统一的 SwiftPM 构建入口。
#
# DSH 的文件沙箱不允许写 ~/Library 下的 SwiftPM/Clang 缓存，也禁止 SwiftPM
# 自带的 sandbox-exec；因此这里统一关掉 sandbox 并把缓存指进工作区。
# 并行开发时用 SCRATCH=.build-<你的名字> 隔离，避免 SwiftPM 全局构建锁互相等待。
set -euo pipefail
cd "$(dirname "$0")/.."
SCRATCH="${SCRATCH:-.build}"
export CLANG_MODULE_CACHE_PATH="$PWD/$SCRATCH/modulecache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/$SCRATCH/modulecache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
echo "+ swift build --disable-sandbox --scratch-path $SCRATCH $*" >&2
exec swift build --disable-sandbox --scratch-path "$SCRATCH" "$@"
