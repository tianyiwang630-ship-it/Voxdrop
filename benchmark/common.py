from __future__ import annotations

import json
import platform
import re
import subprocess
import unicodedata
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[1]


def load_manifest(path: Path | None = None) -> list[dict[str, Any]]:
    path = path or ROOT / "benchmark" / "manifest.yaml"
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    samples = data["samples"]
    for sample in samples:
        sample["audio_path"] = ROOT / sample["audio"]
        sample["prepared_path"] = ROOT / "data" / "prepared" / f"{sample['id']}.wav"
        sample["reference_text"] = (ROOT / sample["reference"]).read_text(encoding="utf-8").strip()
    return samples


def audio_duration(path: Path) -> float:
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
        check=True,
        capture_output=True,
        text=True,
    )
    return float(result.stdout.strip())


def normalize_text(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).lower()
    text = text.replace("’", "'").replace("‘", "'")
    text = re.sub(r"[^\w\u4e00-\u9fff]+", "", text, flags=re.UNICODE)
    return text


def mixed_tokens(text: str) -> list[str]:
    text = unicodedata.normalize("NFKC", text).lower()
    return re.findall(r"[\u4e00-\u9fff]|[a-z0-9]+", text)


def edit_distance(reference: list[str], hypothesis: list[str]) -> int:
    previous = list(range(len(hypothesis) + 1))
    for i, ref_token in enumerate(reference, start=1):
        current = [i]
        for j, hyp_token in enumerate(hypothesis, start=1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (ref_token != hyp_token)))
        previous = current
    return previous[-1]


def error_rate(reference_tokens: list[str], hypothesis_tokens: list[str]) -> float:
    if not reference_tokens:
        return 0.0 if not hypothesis_tokens else 1.0
    return edit_distance(reference_tokens, hypothesis_tokens) / len(reference_tokens)


def hardware_info() -> dict[str, Any]:
    def command(*args: str) -> str:
        result = subprocess.run(args, capture_output=True, text=True)
        return result.stdout.strip() if result.returncode == 0 else ""

    return {
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "processor": command("sysctl", "-n", "machdep.cpu.brand_string") or platform.processor(),
        "memory_bytes": int(command("sysctl", "-n", "hw.memsize") or 0),
    }


def write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
