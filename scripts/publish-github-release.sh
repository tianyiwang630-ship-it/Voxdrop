#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
APP="$PROJECT_ROOT/build/release/言落.app"
DIST_DIR="$PROJECT_ROOT/dist"
if [[ ! -f "$APP/Contents/Info.plist" ]]; then
  echo "请先运行 scripts/build-macos-release.sh 和 scripts/create-macos-dmg.sh" >&2
  exit 2
fi
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
TAG=${1:-v$VERSION}
DMG="$DIST_DIR/VoxDrop-$VERSION-macos-arm64.dmg"
REPORT="$DIST_DIR/release-validation.json"

if ! command -v gh >/dev/null 2>&1; then
  echo "发布维护者机器缺少 GitHub CLI（gh）；最终用户不需要它" >&2
  exit 2
fi
if [[ -n "$(git -C "$PROJECT_ROOT" status --porcelain)" ]]; then
  echo "Git 工作区不是干净状态；先提交并重新构建候选，避免 Release 与源码不一致" >&2
  exit 1
fi
(
  cd "$DIST_DIR"
  shasum -a 256 -c SHA256SUMS.txt
)
"$SCRIPT_DIR/verify-macos-bundle.py" "$APP"
/usr/bin/python3 - "$REPORT" <<'PY'
import json
import sys
from pathlib import Path

report = json.loads(Path(sys.argv[1]).read_text())
failed = {key: value for key, value in report["automated_checks"].items() if value != "passed"}
manual = {key: value for key, value in report["manual_external_checks"].items() if value != "passed"}
if failed:
    raise SystemExit(f"automated release checks are incomplete: {failed}")
if manual:
    raise SystemExit(f"manual release checks are incomplete: {manual}")
PY
CURRENT_COMMIT=$(git -C "$PROJECT_ROOT" rev-parse HEAD)
/usr/bin/python3 - "$APP/Contents/Resources/release-manifest.json" "$CURRENT_COMMIT" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())
if manifest["source"]["dirty"]:
    raise SystemExit("release app was built from a dirty worktree; rebuild after committing")
if manifest["source"]["commit"] != sys.argv[2]:
    raise SystemExit("release app commit does not match current HEAD; rebuild the candidate")
PY
TAG_COMMIT=$(git -C "$PROJECT_ROOT" rev-parse "$TAG^{commit}" 2>/dev/null || true)
if [[ "$TAG_COMMIT" != "$CURRENT_COMMIT" ]]; then
  echo "发布标签不存在或不指向当前提交：$TAG" >&2
  exit 1
fi
gh auth status
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "GitHub Release 已存在，拒绝覆盖：$TAG" >&2
  exit 1
fi
gh release create "$TAG" \
  "$DMG" "$DIST_DIR/SHA256SUMS.txt" "$REPORT" \
  --repo tianyiwang630-ship-it/Voxdrop \
  --title "言落 VoxDrop $VERSION" \
  --notes-file "$DIST_DIR/release-notes.md" \
  --verify-tag

echo "published_release=$TAG"
