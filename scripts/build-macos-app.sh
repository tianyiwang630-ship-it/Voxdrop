#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
PACKAGE_DIR="$PROJECT_ROOT/apps/macos"
BUILD_ROOT="$PROJECT_ROOT/build"
APP="$BUILD_ROOT/VoiceInput.app"

export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.cache/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.cache/swiftpm-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

swift build --disable-sandbox --package-path "$PACKAGE_DIR" -c debug
BIN_DIR=$(swift build --disable-sandbox --package-path "$PACKAGE_DIR" -c debug --show-bin-path)
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VoiceInputApp" "$APP/Contents/MacOS/VoiceInputApp"
cp "$PACKAGE_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
printf '%s\n' "$PROJECT_ROOT" > "$APP/Contents/Resources/development-project-root.txt"
# Embed a stable development designated requirement. Without it, ad-hoc signing
# defaults to a CDHash requirement and every rebuild invalidates TCC permissions.
codesign --force --sign - --identifier com.local.VoiceInput \
  --requirements '=designated => identifier "com.local.VoiceInput"' "$APP"
echo "$APP"
