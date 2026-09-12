from __future__ import annotations

import argparse
import json
import math
import re
import statistics
from collections import defaultdict
from pathlib import Path
from typing import Any

from benchmark.common import error_rate, load_manifest, mixed_tokens, normalize_text, write_json

PUNCTUATION_MAP = {
    ",": ",", "，": ",", ".": ".", "。": ".", "?": "?", "？": "?",
    "!": "!", "！": "!", ";": ";", "；": ";", ":": ":", "：": ":",
}


def percentile(values: list[float], fraction: float) -> float:
    values = sorted(values)
    if not values:
        return 0.0
    index = (len(values) - 1) * fraction
    lower, upper = math.floor(index), math.ceil(index)
    if lower == upper:
        return values[lower]
    return values[lower] * (upper - index) + values[upper] * (index - lower)


def punctuation_counts(text: str) -> dict[str, int]:
    counts = {symbol: 0 for symbol in set(PUNCTUATION_MAP.values())}
    for char in text:
        if char in PUNCTUATION_MAP:
            counts[PUNCTUATION_MAP[char]] += 1
    return counts


def score_run(run_dir: Path) -> dict[str, Any]:
    samples = {s["id"]: s for s in load_manifest()}
    records = [json.loads(line) for line in (run_dir / "predictions.jsonl").read_text(encoding="utf-8").splitlines() if line.strip()]
    scene_totals: dict[str, dict[str, float]] = defaultdict(lambda: {"edits": 0, "reference_tokens": 0, "inference_seconds": 0, "audio_seconds": 0})
    hotword_hits = hotword_total = 0
    punctuation_reference = {symbol: 0 for symbol in set(PUNCTUATION_MAP.values())}
    punctuation_hypothesis = {symbol: 0 for symbol in set(PUNCTUATION_MAP.values())}

    for record in records:
        sample = samples[record["sample_id"]]
        ref_tokens = mixed_tokens(sample["reference_text"])
        hyp_tokens = mixed_tokens(record["text"])
        edits = error_rate(ref_tokens, hyp_tokens) * len(ref_tokens)
        record["reference_text"] = sample["reference_text"]
        record["normalized_reference"] = normalize_text(sample["reference_text"])
        record["normalized_text"] = normalize_text(record["text"])
        record["error_rate"] = edits / len(ref_tokens) if ref_tokens else 0
        record["metric"] = "CER" if sample["language"] == "zh" else "WER" if sample["language"] == "en" else "MER"
        totals = scene_totals[sample["scene"]]
        totals["edits"] += edits
        totals["reference_tokens"] += len(ref_tokens)
        totals["inference_seconds"] += record["inference_seconds"]
        totals["audio_seconds"] += record["audio_seconds"]
        normalized_hyp = normalize_text(record["text"])
        record_hits = 0
        for term in sample.get("hotwords", []):
            hotword_total += 1
            if normalize_text(term) in normalized_hyp:
                hotword_hits += 1
                record_hits += 1
        record["hotword_hits"] = record_hits
        record["hotword_total"] = len(sample.get("hotwords", []))
        for symbol, count in punctuation_counts(sample["reference_text"]).items():
            punctuation_reference[symbol] += count
        for symbol, count in punctuation_counts(record["text"]).items():
            punctuation_hypothesis[symbol] += count

    scene_metrics = {}
    for scene, totals in scene_totals.items():
        scene_metrics[scene] = {
            "error_rate": totals["edits"] / totals["reference_tokens"],
            "rtf": totals["inference_seconds"] / totals["audio_seconds"],
            **totals,
        }
    overall_tokens = sum(v["reference_tokens"] for v in scene_totals.values())
    overall_edits = sum(v["edits"] for v in scene_totals.values())
    total_audio = sum(v["audio_seconds"] for v in scene_totals.values())
    total_inference = sum(v["inference_seconds"] for v in scene_totals.values())
    punctuation_correct = sum(min(punctuation_reference[s], punctuation_hypothesis[s]) for s in punctuation_reference)
    punctuation_ref_total = sum(punctuation_reference.values())
    punctuation_hyp_total = sum(punctuation_hypothesis.values())
    punctuation_precision = punctuation_correct / punctuation_hyp_total if punctuation_hyp_total else 0.0
    punctuation_recall = punctuation_correct / punctuation_ref_total if punctuation_ref_total else 0.0
    punctuation_f1 = 2 * punctuation_precision * punctuation_recall / (punctuation_precision + punctuation_recall) if punctuation_precision + punctuation_recall else 0.0
    inference_values = [r["inference_seconds"] for r in records]
    rtf_values = [r["rtf"] for r in records]
    metrics = {
        "model": records[0]["model"] if records else "unknown",
        "mode": records[0].get("mode", "baseline") if records else "unknown",
        "sample_count": len(records),
        "overall_mer": overall_edits / overall_tokens,
        "overall_rtf": total_inference / total_audio,
        "total_audio_seconds": total_audio,
        "total_inference_seconds": total_inference,
        "latency_median_seconds": statistics.median(inference_values),
        "latency_p95_seconds": percentile(inference_values, 0.95),
        "rtf_median": statistics.median(rtf_values),
        "rtf_p95": percentile(rtf_values, 0.95),
        "load_seconds": records[0].get("load_seconds") if records else None,
        "peak_rss_mb": max((r.get("peak_rss_mb", 0) for r in records), default=0),
        "peak_metal_mb": max((r.get("peak_metal_mb", 0) for r in records), default=0),
        "hotword_recall": hotword_hits / hotword_total if hotword_total else None,
        "hotword_hits": hotword_hits,
        "hotword_total": hotword_total,
        "punctuation_count_precision": punctuation_precision,
        "punctuation_count_recall": punctuation_recall,
        "punctuation_count_f1": punctuation_f1,
        "punctuation_reference_count": punctuation_ref_total,
        "punctuation_hypothesis_count": punctuation_hyp_total,
        "scenes": scene_metrics,
    }
    (run_dir / "predictions.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in records), encoding="utf-8")
    write_json(run_dir / "metrics.json", metrics)
    return metrics


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_dir", type=Path)
    args = parser.parse_args()
    print(json.dumps(score_run(args.run_dir), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
