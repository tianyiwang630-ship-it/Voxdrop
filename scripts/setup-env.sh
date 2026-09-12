#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=project-env.sh
source "$SCRIPT_DIR/project-env.sh"
cd "$VOICE_IME_ROOT"

for command_name in uv curl ffmpeg cmake ninja pkg-config; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

mkdir -p \
  models/sherpa \
  models/funasr \
  models/qwen3-asr \
  models/faster-whisper \
  models/nemotron \
  runtimes \
  results

echo "Installing project-local Python 3.11..."
uv python install 3.11 --install-dir "$UV_PYTHON_INSTALL_DIR" --no-bin

echo "Syncing shared environment..."
uv sync --project "$VOICE_IME_ROOT" --python 3.11

for backend in sherpa funasr mlx faster-whisper; do
  echo "Syncing $backend environment..."
  uv sync --project "$VOICE_IME_ROOT/envs/$backend" --python 3.11
done

NEMO_PREFIX="$VOICE_IME_ROOT/runtimes/nemo-speech"
NEMO_INSTALLER="$VOICE_IME_ROOT/.cache/install-nemo-speech.sh"
if [[ ! -x "$NEMO_PREFIX/bin/nemo-speech" ]]; then
  echo "Installing NeMo-Speech.cpp into $NEMO_PREFIX..."
  curl -fsSL \
    https://github.com/NVIDIA/NeMo-Speech.cpp/raw/main/scripts/install.sh \
    -o "$NEMO_INSTALLER"
  sh "$NEMO_INSTALLER" --prefix "$NEMO_PREFIX" --no-modify-path

  # The upstream installer always creates this convenience symlink even when
  # --no-modify-path is used. Remove it only when it points at this project.
  USER_LOCAL_NEMO_LINK="${HOME}/.local/bin/nemo-speech"
  if [[ -L "$USER_LOCAL_NEMO_LINK" ]] && \
     [[ "$(readlink "$USER_LOCAL_NEMO_LINK")" == "$NEMO_PREFIX/bin/nemo-speech" ]]; then
    unlink "$USER_LOCAL_NEMO_LINK"
  fi
else
  echo "NeMo-Speech.cpp is already installed; leaving it unchanged."
fi

"$SCRIPT_DIR/verify-env.sh"
