#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
APP=${1:-$PROJECT_ROOT/build/release/言落.app}
DIST_DIR=${VOXDROP_DIST_DIR:-$PROJECT_ROOT/dist}
if [[ ! -d "$APP/Contents" ]]; then
  echo "找不到已组装 App：$APP" >&2
  exit 2
fi
APP=${APP:A}
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG_NAME="VoxDrop-$VERSION-macos-arm64.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

mkdir -p "$DIST_DIR"
VOLUME_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/voxdrop-dmg-source.XXXXXX")
cleanup() { rm -rf "$VOLUME_ROOT"; }
trap cleanup EXIT
ditto --noqtn "$APP" "$VOLUME_ROOT/言落.app"
ln -s /Applications "$VOLUME_ROOT/Applications"

ULFO_CANDIDATE="$DIST_DIR/.$DMG_NAME.ulfo.tmp.dmg"
UDZO_CANDIDATE="$DIST_DIR/.$DMG_NAME.udzo.tmp.dmg"
rm -f "$ULFO_CANDIDATE" "$UDZO_CANDIDATE" "$DMG_PATH"
hdiutil create -srcfolder "$VOLUME_ROOT" -volname "言落 $VERSION" -fs HFS+ \
  -format ULFO -ov "$ULFO_CANDIDATE"
SELECTED="$ULFO_CANDIDATE"
SELECTED_BYTES=$(stat -f %z "$SELECTED")

if (( SELECTED_BYTES >= 1000000000 )) || [[ "${VOXDROP_COMPARE_DMG_FORMATS:-0}" == "1" ]]; then
  hdiutil create -srcfolder "$VOLUME_ROOT" -volname "言落 $VERSION" -fs HFS+ \
    -format UDZO -imagekey zlib-level=9 -ov "$UDZO_CANDIDATE"
  UDZO_BYTES=$(stat -f %z "$UDZO_CANDIDATE")
  if (( UDZO_BYTES < SELECTED_BYTES )); then
    SELECTED="$UDZO_CANDIDATE"
    SELECTED_BYTES=$UDZO_BYTES
  fi
fi
if (( SELECTED_BYTES >= 1000000000 )); then
  echo "压缩后的 DMG 仍超过发布上限：$SELECTED_BYTES bytes" >&2
  exit 1
fi
mv "$SELECTED" "$DMG_PATH"
rm -f "$ULFO_CANDIDATE" "$UDZO_CANDIDATE"

"$SCRIPT_DIR/verify-release.sh" "$APP" "$DMG_PATH"
(
  cd "$DIST_DIR"
  shasum -a 256 "$DMG_NAME" > SHA256SUMS.txt
)
cp "$PROJECT_ROOT/docs/GitHub-Release说明.md" "$DIST_DIR/release-notes.md"
VALIDATION_ARGUMENTS=("$APP" "$DMG_PATH" "$DIST_DIR/release-validation.json")
if [[ -n "${VOXDROP_REAL_AUDIO:-}" ]]; then VALIDATION_ARGUMENTS+=(--real-inference-passed); fi
"$SCRIPT_DIR/write-release-validation.py" "${VALIDATION_ARGUMENTS[@]}"

echo "dmg=$DMG_PATH"
echo "dmg_bytes=$(stat -f %z "$DMG_PATH")"
