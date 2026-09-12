#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=project-env.sh
source "$SCRIPT_DIR/project-env.sh"
cd "$VOICE_IME_ROOT"

echo "System tools"
ffmpeg -version | head -n 1
cmake --version | head -n 1
printf 'ninja %s\n' "$(ninja --version)"
printf 'sentencepiece %s\n' "$(pkg-config --modversion sentencepiece)"

echo "Shared Python environment"
uv run --project "$VOICE_IME_ROOT" --frozen python -c \
  'import sys; assert sys.version_info[:2] == (3, 11); import huggingface_hub, jiwer, numpy, psutil, yaml, soundfile; print(sys.version)'

echo "Sherpa-ONNX environment"
uv run --project "$VOICE_IME_ROOT/envs/sherpa" --frozen python -c \
  'import sherpa_onnx; print(sherpa_onnx.__version__)'

echo "FunASR-ONNX environment"
uv run --project "$VOICE_IME_ROOT/envs/funasr" --frozen python -c \
  'import funasr_onnx; print(funasr_onnx.__file__)'

echo "MLX Audio environment"
uv run --project "$VOICE_IME_ROOT/envs/mlx" --frozen python -c \
  'import mlx_audio; print(mlx_audio.__file__)'

echo "faster-whisper environment"
uv run --project "$VOICE_IME_ROOT/envs/faster-whisper" --frozen python -c \
  'import faster_whisper; print(faster_whisper.__version__)'

echo "NeMo-Speech.cpp runtime"
"$VOICE_IME_ROOT/runtimes/nemo-speech/bin/nemo-speech" --version

echo "All environment checks passed."
