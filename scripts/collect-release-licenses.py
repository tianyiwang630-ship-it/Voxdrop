#!/usr/bin/env python3
"""Collect license files already present in the locked runtime into the app."""

from __future__ import annotations

import email.parser
import shutil
import sys
from pathlib import Path


def fail(message: str) -> "NoReturn":
    raise SystemExit(message)


def main() -> None:
    if len(sys.argv) != 4:
        fail("usage: collect-release-licenses.py RUNTIME MODEL_DIR OUTPUT_DIR")
    runtime, model, output = map(Path, sys.argv[1:])
    site = runtime / "lib/python3.11/site-packages"
    python_license = runtime / "lib/python3.11/LICENSE.txt"
    if not python_license.is_file() or not site.is_dir() or not model.is_dir():
        fail("runtime/model input is incomplete")
    if output.exists() and any(output.iterdir()):
        fail(f"license output directory must be empty: {output}")
    output.mkdir(parents=True, exist_ok=True)
    shutil.copy2(python_license, output / "Python-3.11-LICENSE.txt")

    packages = output / "python-packages"
    packages.mkdir()
    rows: list[tuple[str, str, str]] = []
    apache_license: Path | None = None
    for dist in sorted(site.glob("*.dist-info"), key=lambda item: item.name.lower()):
        metadata_path = dist / "METADATA"
        if not metadata_path.is_file():
            continue
        metadata = email.parser.Parser().parsestr(metadata_path.read_text(errors="replace"))
        name = metadata.get("Name", dist.name)
        version = metadata.get("Version", "unknown")
        license_expression = metadata.get("License-Expression") or metadata.get("License") or "see bundled license"
        rows.append((name, version, " ".join(license_expression.split())))
        destination = packages / dist.name
        copied = False
        for candidate in sorted(dist.iterdir()):
            lower = candidate.name.lower()
            if candidate.is_dir() and lower in {"license", "licenses"}:
                shutil.copytree(candidate, destination / candidate.name)
                copied = True
                if name.lower() == "transformers":
                    possible = next((p for p in candidate.rglob("*") if p.is_file()), None)
                    apache_license = possible or apache_license
            elif candidate.is_file() and (lower.startswith("license") or lower.startswith("copying")):
                destination.mkdir(parents=True, exist_ok=True)
                shutil.copy2(candidate, destination / candidate.name)
                copied = True
        if not copied:
            destination.mkdir(parents=True, exist_ok=True)
            (destination / "METADATA-license-fields.txt").write_text(
                f"Name: {name}\nVersion: {version}\nLicense: {license_expression}\n",
                encoding="utf-8",
            )

    shutil.copy2(model / "README.md", output / "Qwen3-ASR-0.6B-4bit-MODEL-CARD.md")
    if apache_license is None:
        fail("could not locate the Apache-2.0 license text used by the bundled model")
    shutil.copy2(apache_license, output / "Apache-2.0.txt")

    notice = [
        "# 言落第三方组件声明",
        "",
        "本应用内置 CPython 3.11、以下 Python 包以及本地语音模型。许可证全文随本目录分发。",
        "",
        "模型 `mlx-community/Qwen3-ASR-0.6B-4bit` 的模型卡声明为 Apache-2.0；",
        "原始模型为 `Qwen/Qwen3-ASR-0.6B`。详见随附模型卡与 `Apache-2.0.txt`。",
        "",
        "| Python 包 | 版本 | 元数据中的许可证 |",
        "| --- | --- | --- |",
    ]
    notice.extend(f"| {name} | {version} | {license_value.replace('|', '/')} |" for name, version, license_value in rows)
    notice.append("")
    (output / "THIRD-PARTY-NOTICES.md").write_text("\n".join(notice), encoding="utf-8")
    print(output)


if __name__ == "__main__":
    main()
