#!/usr/bin/env python3
"""Fail closed when a release app is not relocatable and self-contained."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
from pathlib import Path

MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}
TEXT_SUFFIXES = {".cfg", ".json", ".pth", ".py", ".sh", ".txt"}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def command(*arguments: str) -> str:
    return subprocess.run(arguments, check=True, text=True, capture_output=True).stdout


def is_macho(path: Path) -> bool:
    try:
        with path.open("rb") as source:
            return source.read(4) in MACHO_MAGICS
    except OSError:
        return False


def version_tuple(raw: str) -> tuple[int, ...]:
    return tuple(int(part) for part in raw.split("."))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--skip-signature", action="store_true")
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    contents = app / "Contents"
    resources = contents / "Resources"
    errors: list[str] = []

    required = [
        contents / "MacOS/VoxDrop",
        contents / "Info.plist",
        resources / "release-manifest.json",
        resources / "runtime/bin/python3.11",
        resources / "runtime/lib/python3.11/site-packages/voice_input/worker.py",
        resources / "models/qwen3-asr/Qwen3-ASR-0.6B-4bit/config.json",
        resources / "models/qwen3-asr/Qwen3-ASR-0.6B-4bit/model.safetensors",
        resources / "licenses/THIRD-PARTY-NOTICES.md",
    ]
    errors.extend(f"missing required release file: {path.relative_to(app)}" for path in required if not path.is_file())
    if errors:
        raise SystemExit("\n".join(errors))

    with (contents / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info.get("LSMinimumSystemVersion") != "26.2":
        errors.append("Info.plist LSMinimumSystemVersion must be exactly 26.2")
    if info.get("CFBundleIdentifier") != "com.local.VoxDrop":
        errors.append("unexpected bundle identifier")

    manifest = json.loads((resources / "release-manifest.json").read_text(encoding="utf-8"))
    if manifest.get("schema_version") != 1 or manifest.get("architecture") != "arm64":
        errors.append("release manifest schema/architecture is invalid")
    model = resources / "models/qwen3-asr/Qwen3-ASR-0.6B-4bit"
    hashes = manifest.get("model", {}).get("sha256", {})
    for filename in ("config.json", "model.safetensors"):
        if hashes.get(filename) != sha256(model / filename):
            errors.append(f"model digest mismatch: {filename}")

    macho_files: list[Path] = []
    for path in app.rglob("*"):
        if path.is_symlink():
            target = os.readlink(path)
            if os.path.isabs(target):
                errors.append(f"absolute symlink: {path.relative_to(app)} -> {target}")
            if not path.exists():
                errors.append(f"broken symlink: {path.relative_to(app)} -> {target}")
            continue
        if not path.is_file():
            continue
        if path.name == "pyvenv.cfg" or path.name == "development-project-root.txt":
            errors.append(f"development-only file bundled: {path.relative_to(app)}")
        is_sbom = "sboms" in path.parts
        if not is_sbom and path.suffix.lower() in TEXT_SUFFIXES and path.stat().st_size <= 8 * 1024 * 1024:
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                text = ""
            if "/Users/" in text or "VOXDROP_PROJECT_ROOT" in text or "VOICE_INPUT_PROJECT_ROOT" in text:
                errors.append(f"development path/config reference: {path.relative_to(app)}")
        if is_macho(path):
            macho_files.append(path)

    if not macho_files:
        errors.append("no Mach-O files found")
    for path in macho_files:
        relative = path.relative_to(app)
        description = command("/usr/bin/file", str(path))
        if "arm64" not in description:
            errors.append(f"Mach-O lacks arm64: {relative}")
        build = command("/usr/bin/vtool", "-show-build", str(path))
        min_versions = re.findall(r"^\s*minos\s+([0-9.]+)\s*$", build, flags=re.MULTILINE)
        for minimum in min_versions:
            if version_tuple(minimum) > version_tuple("26.2"):
                errors.append(f"Mach-O minimum macOS exceeds 26.2: {relative} ({minimum})")
        install_ids = {
            line.strip() for line in command("/usr/bin/otool", "-D", str(path)).splitlines()[1:]
            if line.strip() and not line.rstrip().endswith(":")
        }
        linked = command("/usr/bin/otool", "-L", str(path)).splitlines()[1:]
        for line in linked:
            if " (compatibility version " not in line:
                continue
            dependency = line.strip().split(" (", 1)[0]
            if dependency in install_ids:
                continue
            if dependency.startswith(("/System/Library/", "/usr/lib/", "@rpath/", "@loader_path/", "@executable_path/")):
                continue
            errors.append(f"non-system absolute dependency: {relative} -> {dependency}")

    if not args.skip_signature:
        verification = subprocess.run(
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)],
            text=True,
            capture_output=True,
        )
        if verification.returncode:
            errors.append(f"code signature verification failed: {verification.stderr.strip()}")

    if errors:
        raise SystemExit("bundle verification failed:\n- " + "\n- ".join(errors))
    print(json.dumps({"status": "passed", "app": str(app), "mach_o_files": len(macho_files)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
