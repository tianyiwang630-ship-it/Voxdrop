#!/usr/bin/env bash

# Source this file for ad-hoc commands so managed artifacts stay in the project.
if [[ -n "${ZSH_VERSION:-}" ]]; then
  VOICE_IME_ENV_FILE="${(%):-%N}"
else
  VOICE_IME_ENV_FILE="${BASH_SOURCE[0]}"
fi
VOICE_IME_ROOT="$(CDPATH= cd -- "$(dirname -- "$VOICE_IME_ENV_FILE")/.." && pwd)"

# A uv installed inside pyenv can become unreachable after this project pins
# Python 3.11. Resolve its real executable once, then shadow the broken shim.
VOICE_IME_UV="$(command -v uv 2>/dev/null || true)"
if [[ -z "$VOICE_IME_UV" ]] || ! "$VOICE_IME_UV" --version >/dev/null 2>&1; then
  if command -v pyenv >/dev/null 2>&1; then
    while IFS= read -r pyenv_version; do
      uv_candidate="$(PYENV_VERSION="$pyenv_version" pyenv which uv 2>/dev/null || true)"
      if [[ -x "$uv_candidate" ]]; then
        VOICE_IME_UV="$uv_candidate"
        break
      fi
    done < <(pyenv versions --bare)
  fi
fi

if [[ -z "$VOICE_IME_UV" ]] || ! "$VOICE_IME_UV" --version >/dev/null 2>&1; then
  echo "Unable to locate a working uv executable." >&2
  return 1 2>/dev/null || exit 1
fi

uv() {
  "$VOICE_IME_UV" "$@"
}

export VOICE_IME_ROOT
export VOICE_IME_UV
export UV_CACHE_DIR="$VOICE_IME_ROOT/.cache/uv"
export UV_PYTHON_INSTALL_DIR="$VOICE_IME_ROOT/.cache/python"
export UV_PYTHON_INSTALL_BIN=0
export HF_HOME="$VOICE_IME_ROOT/.cache/huggingface"
export HUGGINGFACE_HUB_CACHE="$HF_HOME/hub"
export MODELSCOPE_CACHE="$VOICE_IME_ROOT/.cache/modelscope"
export XDG_CACHE_HOME="$VOICE_IME_ROOT/.cache/xdg"
export TMPDIR="$VOICE_IME_ROOT/.cache/tmp"
export ORT_DISABLE_TELEMETRY=1

mkdir -p \
  "$UV_CACHE_DIR" \
  "$UV_PYTHON_INSTALL_DIR" \
  "$HUGGINGFACE_HUB_CACHE" \
  "$MODELSCOPE_CACHE" \
  "$XDG_CACHE_HOME" \
  "$TMPDIR"
