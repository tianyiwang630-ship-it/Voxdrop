#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
PACKAGE_DIR="$PROJECT_ROOT/apps/macos"
BUILD_ROOT=${VOXDROP_RELEASE_BUILD_ROOT:-$PROJECT_ROOT/build/release}
APP="$BUILD_ROOT/言落.app"
MODEL_SOURCE="$PROJECT_ROOT/models/qwen3-asr/Qwen3-ASR-0.6B-4bit"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "发行版必须在 Apple Silicon Mac 上构建" >&2
  exit 2
fi
if [[ ! -f "$MODEL_SOURCE/model.safetensors" ]]; then
  echo "模型文件不存在：$MODEL_SOURCE/model.safetensors" >&2
  exit 2
fi

export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.cache/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.cache/swiftpm-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE" "$BUILD_ROOT"

swift build --disable-sandbox --package-path "$PACKAGE_DIR" -c release --product VoxDrop
BIN_DIR=$(swift build --disable-sandbox --package-path "$PACKAGE_DIR" -c release --show-bin-path)

if [[ "$APP" != "$BUILD_ROOT/言落.app" ]]; then
  echo "拒绝清理意外的 App 路径：$APP" >&2
  exit 2
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VoxDrop" "$APP/Contents/MacOS/VoxDrop"
cp "$PACKAGE_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$PACKAGE_DIR/Resources/VoxDrop.icns" "$APP/Contents/Resources/VoxDrop.icns"

"$SCRIPT_DIR/package-python-runtime.sh" "$APP/Contents/Resources/runtime"
mkdir -p "$APP/Contents/Resources/models/qwen3-asr"
ditto --noqtn "$MODEL_SOURCE" "$APP/Contents/Resources/models/qwen3-asr/Qwen3-ASR-0.6B-4bit"

"$SCRIPT_DIR/collect-release-licenses.py" \
  "$APP/Contents/Resources/runtime" \
  "$APP/Contents/Resources/models/qwen3-asr/Qwen3-ASR-0.6B-4bit" \
  "$APP/Contents/Resources/licenses"
"$SCRIPT_DIR/generate-release-manifest.py" \
  "$PROJECT_ROOT" "$APP" "$APP/Contents/Resources/release-manifest.json"

xattr -cr "$APP"
"$SCRIPT_DIR/verify-macos-bundle.py" --skip-signature "$APP"
"$SCRIPT_DIR/smoke-packaged-worker.py" "$APP"
"$SCRIPT_DIR/sign-macos-app.sh" "$APP"
"$SCRIPT_DIR/verify-macos-bundle.py" "$APP"

APP_BYTES=$(du -sk "$APP" | awk '{print $1 * 1024}')
echo "release_app=$APP"
echo "release_app_bytes=$APP_BYTES"
