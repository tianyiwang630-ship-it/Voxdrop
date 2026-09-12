#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.cache/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.cache/swiftpm-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
swift run --disable-sandbox --package-path "$PROJECT_ROOT/apps/macos" VoiceInputCoreChecks

