#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
APP=${1:-}
DMG=${2:-}
if [[ -z "$APP" ]] || [[ -z "$DMG" ]] || [[ ! -d "$APP/Contents" ]] || [[ ! -f "$DMG" ]]; then
  echo "用法：$0 <言落.app> <VoxDrop.dmg>" >&2
  exit 2
fi
APP=${APP:A}
DMG=${DMG:A}
DMG_BYTES=$(stat -f %z "$DMG")
if (( DMG_BYTES >= 1000000000 )); then
  echo "DMG 超过发布上限：$DMG_BYTES bytes" >&2
  exit 1
fi
if (( DMG_BYTES >= 950000000 )); then
  echo "警告：DMG 已达到 950 MB 预警线：$DMG_BYTES bytes" >&2
fi
hdiutil verify "$DMG" -quiet

"$SCRIPT_DIR/verify-macos-bundle.py" "$APP"
"$SCRIPT_DIR/smoke-packaged-worker.py" "$APP"

MOUNT_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/voxdrop-dmg-mount.XXXXXX")
COPY_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/voxdrop-dmg-copy.XXXXXX")
mounted=0
cleanup() {
  if (( mounted )); then hdiutil detach "$MOUNT_ROOT" -quiet || true; fi
  rm -rf "$MOUNT_ROOT" "$COPY_ROOT"
}
trap cleanup EXIT
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT_ROOT" -quiet
mounted=1
MOUNTED_APP="$MOUNT_ROOT/言落.app"
"$SCRIPT_DIR/verify-macos-bundle.py" "$MOUNTED_APP"
"$SCRIPT_DIR/smoke-packaged-worker.py" "$MOUNTED_APP"
ditto --noqtn "$MOUNTED_APP" "$COPY_ROOT/言落.app"
hdiutil detach "$MOUNT_ROOT" -quiet
mounted=0
"$SCRIPT_DIR/verify-macos-bundle.py" "$COPY_ROOT/言落.app"
if [[ -n "${VOXDROP_REAL_AUDIO:-}" ]]; then
  "$SCRIPT_DIR/smoke-packaged-worker.py" "$COPY_ROOT/言落.app" \
    --real-audio "$VOXDROP_REAL_AUDIO" --startup-timeout 180
else
  "$SCRIPT_DIR/smoke-packaged-worker.py" "$COPY_ROOT/言落.app"
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$COPY_ROOT/言落.app"

echo "release_verification=passed"
echo "dmg_bytes=$DMG_BYTES"
