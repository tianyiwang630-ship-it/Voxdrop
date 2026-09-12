from __future__ import annotations

import argparse
import json
import os
import resource
import time
from pathlib import Path

from funasr_onnx import SeacoParaformer


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--hotwords", action="store_true")
    args = parser.parse_args()
    samples = json.loads(args.manifest_json.read_text(encoding="utf-8"))

    # The official snapshot quantizes the acoustic backbone but keeps the small
    # contextual embedding network in float. funasr-onnx expects this alias.
    eb_quant = args.model_dir / "model_eb_quant.onnx"
    if not eb_quant.exists():
        eb_quant.symlink_to("model_eb.onnx")

    started = time.perf_counter()
    model = SeacoParaformer(
        model_dir=args.model_dir,
        quantize=True,
        batch_size=1,
        device_id="-1",
        intra_op_num_threads=4,
    )
    load_seconds = time.perf_counter() - started
    with args.output.open("w", encoding="utf-8") as out:
        for sample in samples:
            # funasr-onnx 0.4.1 encodes whitespace-separated units and hard-limits
            # each unit to 10 characters. Keep only representable units; the
            # omitted long terms are reported as a backend capability limit.
            hotword_units = [
                unit
                for term in sample.get("hotwords", [])
                for unit in term.split()
                if len(unit) <= 10
            ]
            hotwords = " ".join(hotword_units) if args.hotwords else ""
            started = time.perf_counter()
            result = model(sample["audio"], hotwords=hotwords)
            elapsed = time.perf_counter() - started
            text = result[0].get("preds", "") if result else ""
            if isinstance(text, (tuple, list)):
                text = text[0]
            record = {
                "sample_id": sample["id"],
                "model": "seaco-paraformer-contextual-backbone-int8",
                "mode": "hotwords" if args.hotwords else "baseline",
                "text": text.strip(),
                "audio_seconds": sample["duration"],
                "inference_seconds": elapsed,
                "rtf": elapsed / sample["duration"],
                "load_seconds": load_seconds,
                "peak_rss_mb": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 * 1024),
                "pid": os.getpid(),
                "submitted_hotwords": hotword_units if args.hotwords else [],
            }
            out.write(json.dumps(record, ensure_ascii=False) + "\n")
            out.flush()
            print(f"{sample['id']}: {elapsed:.3f}s RTF={record['rtf']:.3f} {record['text']}", flush=True)


if __name__ == "__main__":
    main()
