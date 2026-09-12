from __future__ import annotations

import argparse
import json
import os
import resource
import time
from pathlib import Path

from faster_whisper import WhisperModel


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--model", default="base")
    parser.add_argument("--download-root", type=Path, required=True)
    parser.add_argument("--hotwords", action="store_true")
    args = parser.parse_args()
    samples = json.loads(args.manifest_json.read_text(encoding="utf-8"))

    load_started = time.perf_counter()
    model = WhisperModel(args.model, device="cpu", compute_type="int8", download_root=str(args.download_root))
    load_seconds = time.perf_counter() - load_started
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as out:
        for sample in samples:
            started = time.perf_counter()
            segments, info = model.transcribe(
                sample["audio"],
                beam_size=5,
                vad_filter=False,
                condition_on_previous_text=True,
                hotwords=" ".join(sample.get("hotwords", [])) if args.hotwords else None,
            )
            text = "".join(segment.text for segment in segments).strip()
            elapsed = time.perf_counter() - started
            rss_mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 * 1024)
            record = {
                "sample_id": sample["id"],
                "model": "faster-whisper-base-int8",
                "mode": "hotwords" if args.hotwords else "baseline",
                "text": text,
                "language_detected": info.language,
                "language_probability": info.language_probability,
                "audio_seconds": sample["duration"],
                "inference_seconds": elapsed,
                "rtf": elapsed / sample["duration"],
                "load_seconds": load_seconds,
                "peak_rss_mb": rss_mb,
                "pid": os.getpid(),
            }
            out.write(json.dumps(record, ensure_ascii=False) + "\n")
            out.flush()
            print(f"{sample['id']}: {elapsed:.3f}s RTF={record['rtf']:.3f} {text}", flush=True)


if __name__ == "__main__":
    main()
