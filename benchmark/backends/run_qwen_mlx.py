from __future__ import annotations

import argparse
import json
import os
import resource
import time
from pathlib import Path

import mlx.core as mx
from mlx_audio.stt import load_model


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--hotwords", action="store_true")
    args = parser.parse_args()
    samples = json.loads(args.manifest_json.read_text(encoding="utf-8"))

    mx.metal.reset_peak_memory()
    started = time.perf_counter()
    model = load_model(args.model_dir)
    load_seconds = time.perf_counter() - started
    with args.output.open("w", encoding="utf-8") as out:
        for sample in samples:
            started = time.perf_counter()
            result = model.generate(
                sample["audio"],
                temperature=0.0,
                hotwords=sample.get("hotwords", []) if args.hotwords else None,
            )
            elapsed = time.perf_counter() - started
            record = {
                "sample_id": sample["id"],
                "model": "qwen3-asr-0.6b-mlx-4bit",
                "mode": "hotwords" if args.hotwords else "baseline",
                "text": result.text.strip(),
                "language_detected": result.language,
                "audio_seconds": sample["duration"],
                "inference_seconds": elapsed,
                "rtf": elapsed / sample["duration"],
                "load_seconds": load_seconds,
                "peak_rss_mb": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 * 1024),
                "peak_metal_mb": mx.metal.get_peak_memory() / (1024 * 1024),
                "pid": os.getpid(),
            }
            out.write(json.dumps(record, ensure_ascii=False) + "\n")
            out.flush()
            print(f"{sample['id']}: {elapsed:.3f}s RTF={record['rtf']:.3f} {record['text']}", flush=True)


if __name__ == "__main__":
    main()
