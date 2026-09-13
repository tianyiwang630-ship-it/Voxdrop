#!/usr/bin/env python3
"""Generate the machine-readable manifest embedded in a release app."""

from __future__ import annotations

import hashlib
import importlib.metadata
import json
import plistlib
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def git(project: Path, *arguments: str) -> str | None:
    result = subprocess.run(["git", *arguments], cwd=project, text=True, capture_output=True)
    return result.stdout.strip() if result.returncode == 0 else None


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: generate-release-manifest.py PROJECT_ROOT APP OUTPUT")
    project, app, output = map(Path, sys.argv[1:])
    resources = app / "Contents/Resources"
    model = resources / "models/qwen3-asr/Qwen3-ASR-0.6B-4bit"
    runtime = resources / "runtime"
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    source_config = json.loads((project / "config/runtime-resources.json").read_text())
    distributions = []
    for metadata in sorted((runtime / "lib/python3.11/site-packages").glob("*.dist-info")):
        name_version = metadata.name.removesuffix(".dist-info")
        distributions.append(name_version)
    manifest = {
        "schema_version": 1,
        "product": "VoxDrop",
        "display_name": "言落",
        "version": info["CFBundleShortVersionString"],
        "build": info["CFBundleVersion"],
        "architecture": "arm64",
        "minimum_macos": "26.2",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "source": {
            "commit": git(project, "rev-parse", "HEAD"),
            "dirty": bool(git(project, "status", "--porcelain")),
            "mlx_lock_sha256": sha256(project / "envs/mlx/uv.lock"),
        },
        "python": {
            "version": source_config["python"]["version"],
            "executable": "runtime/bin/python3.11",
            "distributions": distributions,
        },
        "model": {
            "id": source_config["model"]["id"],
            "directory": "models/qwen3-asr/Qwen3-ASR-0.6B-4bit",
            "sha256": {
                "config.json": sha256(model / "config.json"),
                "model.safetensors": sha256(model / "model.safetensors"),
            },
        },
    }
    expected = source_config["model"]
    if manifest["source"]["mlx_lock_sha256"] != source_config["python"]["mlx_lock_sha256"]:
        raise SystemExit("envs/mlx/uv.lock differs from config/runtime-resources.json")
    if manifest["model"]["sha256"]["config.json"] != expected["config_sha256"]:
        raise SystemExit("model config checksum differs from config/runtime-resources.json")
    if manifest["model"]["sha256"]["model.safetensors"] != expected["weights_sha256"]:
        raise SystemExit("model weights checksum differs from config/runtime-resources.json")
    output.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(output)


if __name__ == "__main__":
    main()
