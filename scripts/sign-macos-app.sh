#!/bin/zsh
set -euo pipefail

APP=${1:-}
if [[ -z "$APP" ]] || [[ ! -d "$APP/Contents" ]]; then
  echo "用法：$0 <言落.app>" >&2
  exit 2
fi
APP=${APP:A}
MAIN_EXECUTABLE="$APP/Contents/MacOS/VoxDrop"

# Sign every nested Mach-O first. The outer seal is created only after all
# bundled Python extensions and dylibs are final.
while IFS= read -r -d '' candidate; do
  [[ "$candidate" == "$MAIN_EXECUTABLE" ]] && continue
  if /usr/bin/file -b "$candidate" | /usr/bin/grep -q 'Mach-O'; then
    /usr/bin/codesign --force --sign - --timestamp=none "$candidate"
  fi
done < <(find "$APP" -type f -print0)

/usr/bin/codesign --force --sign - --timestamp=none \
  --identifier com.local.VoxDrop \
  --requirements '=designated => identifier "com.local.VoxDrop"' \
  "$MAIN_EXECUTABLE"
/usr/bin/codesign --force --sign - --timestamp=none \
  --identifier com.local.VoxDrop \
  --requirements '=designated => identifier "com.local.VoxDrop"' \
  "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
echo "$APP"
