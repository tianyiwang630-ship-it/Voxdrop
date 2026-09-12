from __future__ import annotations

import argparse
import json
import os
import subprocess
from datetime import datetime
from pathlib import Path

from benchmark.common import ROOT, audio_duration, hardware_info, load_manifest, write_json
from benchmark.score import score_run


def serializable_manifest() -> list[dict]:
    records = []
    for sample in load_manifest():
        if not sample["prepared_path"].exists():
            raise SystemExit("Prepared audio missing; run `uv run python -m benchmark.prepare_audio` first")
        records.append({
            "id": sample["id"],
            "scene": sample["scene"],
            "language": sample["language"],
            "audio": str(sample["prepared_path"]),
            "duration": audio_duration(sample["prepared_path"]),
            "hotwords": sample.get("hotwords", []),
        })
    return records


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend", choices=["faster-whisper", "qwen-mlx", "sherpa", "funasr", "nemo"], required=True)
    parser.add_argument("--hotwords", action="store_true")
    parser.add_argument("--run-name")
    args = parser.parse_args()
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    mode = "hotwords" if args.hotwords else "baseline"
    run_dir = ROOT / "results" / (args.run_name or f"{timestamp}_{args.backend}_{mode}")
    run_dir.mkdir(parents=True, exist_ok=False)
    manifest_path = run_dir / "input.json"
    write_json(manifest_path, serializable_manifest())
    write_json(run_dir / "run.json", {"backend": args.backend, "mode": mode, "hardware": hardware_info()})

    uv_executable = os.environ.get("VOICE_IME_UV", "uv")
    if args.backend == "faster-whisper":
        command = [
            uv_executable, "run", "--project", str(ROOT / "envs" / "faster-whisper"), "python",
            str(ROOT / "benchmark" / "backends" / "run_faster_whisper.py"),
            "--manifest-json", str(manifest_path),
            "--output", str(run_dir / "predictions.jsonl"),
            "--download-root", str(ROOT / "models" / "faster-whisper"),
        ]
    elif args.backend == "qwen-mlx":
        command = [
            uv_executable, "run", "--project", str(ROOT / "envs" / "mlx"), "python",
            str(ROOT / "benchmark" / "backends" / "run_qwen_mlx.py"),
            "--manifest-json", str(manifest_path),
            "--output", str(run_dir / "predictions.jsonl"),
            "--model-dir", str(ROOT / "models" / "qwen3-asr" / "Qwen3-ASR-0.6B-4bit"),
        ]
    elif args.backend == "sherpa":
        command = [
            uv_executable, "run", "--project", str(ROOT / "envs" / "sherpa"), "python",
            str(ROOT / "benchmark" / "backends" / "run_sherpa.py"),
            "--manifest-json", str(manifest_path),
            "--output", str(run_dir / "predictions.jsonl"),
            "--model-dir", str(ROOT / "models" / "sherpa" / "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20"),
        ]
    elif args.backend == "funasr":
        command = [
            uv_executable, "run", "--project", str(ROOT / "envs" / "funasr"), "python",
            str(ROOT / "benchmark" / "backends" / "run_funasr.py"),
            "--manifest-json", str(manifest_path),
            "--output", str(run_dir / "predictions.jsonl"),
            "--model-dir", str(ROOT / "models" / "funasr" / "seaco-paraformer-contextual-onnx"),
        ]
    else:
        command = [
            uv_executable, "run", "--project", str(ROOT), "python",
            str(ROOT / "benchmark" / "backends" / "run_nemo.py"),
            "--manifest-json", str(manifest_path),
            "--output", str(run_dir / "predictions.jsonl"),
            "--runtime", str(ROOT / "runtimes" / "nemo-speech" / "bin" / "nemo-speech"),
            "--model", str(ROOT / "models" / "nemotron" / "current" / "nemotron-3.5-asr-streaming-0.6b.q8_0.gguf"),
        ]
    if args.hotwords:
        command.append("--hotwords")
    subprocess.run(command, cwd=ROOT, check=True)
    metrics = score_run(run_dir)
    print(json.dumps(metrics, ensure_ascii=False, indent=2))
    print(run_dir)


if __name__ == "__main__":
    main()
