#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
"$SCRIPT_DIR/build-macos-app.sh" >&2
APP="$PROJECT_ROOT/build/言落.app"
defaults write com.local.VoxDrop projectPath "$PROJECT_ROOT"
open "$APP"
