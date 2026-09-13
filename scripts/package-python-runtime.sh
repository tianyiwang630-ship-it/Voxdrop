#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
OUTPUT_DIR=${1:-}
PYTHON_SOURCE=${VOXDROP_PYTHON_SOURCE:-$PROJECT_ROOT/.cache/python/cpython-3.11.15-macos-aarch64-none}
SITE_PACKAGES_SOURCE=${VOXDROP_SITE_PACKAGES_SOURCE:-$PROJECT_ROOT/envs/mlx/.venv/lib/python3.11/site-packages}

if [[ -z "$OUTPUT_DIR" ]]; then
  echo "用法：$0 <空的 runtime 输出目录>" >&2
  exit 2
fi
if [[ "$OUTPUT_DIR" != /* ]]; then OUTPUT_DIR="$PROJECT_ROOT/$OUTPUT_DIR"; fi
if [[ -e "$OUTPUT_DIR" ]] && [[ -n "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  echo "runtime 输出目录必须为空：$OUTPUT_DIR" >&2
  exit 2
fi
if [[ ! -x "$PYTHON_SOURCE/bin/python3.11" ]]; then
  echo "找不到独立 CPython 3.11：$PYTHON_SOURCE/bin/python3.11" >&2
  exit 2
fi
if [[ ! -d "$SITE_PACKAGES_SOURCE/mlx_audio" ]] || [[ ! -d "$SITE_PACKAGES_SOURCE/mlx" ]]; then
  echo "MLX 运行依赖不完整：$SITE_PACKAGES_SOURCE" >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIR"
ditto --noqtn "$PYTHON_SOURCE" "$OUTPUT_DIR"

# Rebuild bin with only the relocatable interpreter. Development CLIs, headers,
# package installers, Tk and caches are not part of the product runtime.
rm -rf "$OUTPUT_DIR/bin"
mkdir -p "$OUTPUT_DIR/bin"
cp "$PYTHON_SOURCE/bin/python3.11" "$OUTPUT_DIR/bin/python3.11"
chmod 755 "$OUTPUT_DIR/bin/python3.11"
ln -s python3.11 "$OUTPUT_DIR/bin/python3"
ln -s python3.11 "$OUTPUT_DIR/bin/python"

rm -rf "$OUTPUT_DIR/include" "$OUTPUT_DIR/share"
rm -rf "$OUTPUT_DIR/lib/pkgconfig" "$OUTPUT_DIR/lib/tk9.0"
rm -f "$OUTPUT_DIR/lib/libtcl9.0.dylib" "$OUTPUT_DIR/lib/libtcl9tk9.0.dylib"
rm -f "$OUTPUT_DIR/lib/libpython3.11.dylib"
rm -rf "$OUTPUT_DIR/lib/tcl9" "$OUTPUT_DIR/lib/tcl9.0" "$OUTPUT_DIR/lib/thread3.0.6" "$OUTPUT_DIR/lib/itcl4.3.8"
rm -rf "$OUTPUT_DIR/lib/python3.11/idlelib" "$OUTPUT_DIR/lib/python3.11/tkinter"
rm -rf "$OUTPUT_DIR/lib/python3.11/turtledemo" "$OUTPUT_DIR/lib/python3.11/ensurepip"
rm -rf "$OUTPUT_DIR/lib/python3.11/venv" "$OUTPUT_DIR/lib/python3.11/test"

RUNTIME_SITE="$OUTPUT_DIR/lib/python3.11/site-packages"
rm -rf "$RUNTIME_SITE"
mkdir -p "$RUNTIME_SITE"
ditto --noqtn "$SITE_PACKAGES_SOURCE" "$RUNTIME_SITE"
ditto --noqtn "$PROJECT_ROOT/voice_input" "$RUNTIME_SITE/voice_input"

rm -f "$RUNTIME_SITE/_virtualenv.pth" "$RUNTIME_SITE/_virtualenv.py"
find "$RUNTIME_SITE" -type d \( -name test -o -name tests \) -prune -exec rm -rf {} +
find "$OUTPUT_DIR/lib/python3.11/lib-dynload" -type f -name '_tkinter*.so' -delete
find "$OUTPUT_DIR" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$OUTPUT_DIR" -type f \( -name '*.pyc' -o -name '*.pyo' -o -name '.DS_Store' \) -delete

SYSCONFIG_DATA="$OUTPUT_DIR/lib/python3.11/_sysconfigdata__darwin_darwin.py"
if [[ -f "$SYSCONFIG_DATA" ]]; then
  /usr/bin/sed -i '' "s|$PYTHON_SOURCE|/nonexistent/voxdrop-runtime|g" "$SYSCONFIG_DATA"
fi

# Keep only arm64 slices and normalize dylib install IDs before signing.
while IFS= read -r -d '' candidate; do
  if /usr/bin/file -b "$candidate" | /usr/bin/grep -q 'Mach-O'; then
    architectures=$(/usr/bin/lipo -archs "$candidate")
    if [[ " $architectures " == *" arm64 "* ]] && [[ "$architectures" == *" "* ]]; then
      /usr/bin/lipo "$candidate" -thin arm64 -output "$candidate.arm64"
      mv "$candidate.arm64" "$candidate"
    fi
  fi
done < <(find "$OUTPUT_DIR" -type f -print0)
while IFS= read -r -d '' library; do
  install_id=$(/usr/bin/otool -D "$library" 2>/dev/null | /usr/bin/sed -n '2p')
  if [[ "$install_id" == /* ]] && [[ "$install_id" != /usr/lib/* ]] && [[ "$install_id" != /System/Library/* ]]; then
    /usr/bin/install_name_tool -id "@rpath/${library:t}" "$library"
  fi
done < <(find "$OUTPUT_DIR" -type f -name '*.dylib' -print0)

while IFS= read -r link; do
  target=$(readlink "$link")
  if [[ "$target" == /* ]]; then
    echo "runtime 内出现绝对符号链接：$link -> $target" >&2
    exit 1
  fi
done < <(find "$OUTPUT_DIR" -type l -print)

RUNTIME_TMP=$(mktemp -d "${TMPDIR:-/tmp}/voxdrop-runtime-check.XXXXXX")
trap 'rm -rf "$RUNTIME_TMP"' EXIT
mkdir -p "$RUNTIME_TMP/home"
env -i HOME="$RUNTIME_TMP/home" TMPDIR="$RUNTIME_TMP" PATH=/usr/bin:/bin \
  HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 \
  "$OUTPUT_DIR/bin/python3.11" -I -B -c \
  'import mlx, mlx_audio, numpy, safetensors, tokenizers, transformers, voice_input; print("bundled runtime imports: passed")'

echo "$OUTPUT_DIR"
