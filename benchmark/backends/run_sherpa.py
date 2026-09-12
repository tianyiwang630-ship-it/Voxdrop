from __future__ import annotations

import argparse
import json
import os
import resource
import time
from pathlib import Path

import numpy as np
import sherpa_onnx
import soundfile as sf


def encoded_hotwords(terms: list[str], model_dir: Path) -> str | None:
    if not terms:
        return None
    tokenized = sherpa_onnx.text2token(
        terms,
        tokens=str(model_dir / "tokens.txt"),
        tokens_type="cjkchar+bpe",
        bpe_model=str(model_dir / "bpe.model"),
    )
    return "/".join(" ".join(tokens) for tokens in tokenized) or None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--hotwords", action="store_true")
    args = parser.parse_args()
    samples = json.loads(args.manifest_json.read_text(encoding="utf-8"))

    started = time.perf_counter()
    recognizer = sherpa_onnx.OnlineRecognizer.from_transducer(
        tokens=str(args.model_dir / "tokens.txt"),
        encoder=str(args.model_dir / "encoder-epoch-99-avg-1.int8.onnx"),
        decoder=str(args.model_dir / "decoder-epoch-99-avg-1.onnx"),
        joiner=str(args.model_dir / "joiner-epoch-99-avg-1.onnx"),
        num_threads=4,
        decoding_method="modified_beam_search" if args.hotwords else "greedy_search",
        max_active_paths=4,
        hotwords_score=1.5,
        model_type="zipformer",
        modeling_unit="cjkchar+bpe",
        bpe_vocab=str(args.model_dir / "bpe.vocab"),
    )
    load_seconds = time.perf_counter() - started
    with args.output.open("w", encoding="utf-8") as out:
        for sample in samples:
            audio, sample_rate = sf.read(sample["audio"], dtype="float32", always_2d=False)
            if audio.ndim > 1:
                audio = audio[:, 0]
            hotword_tokens = encoded_hotwords(sample.get("hotwords", []), args.model_dir) if args.hotwords else None
            stream = recognizer.create_stream(hotword_tokens)
            started = time.perf_counter()
            stream.accept_waveform(sample_rate, np.ascontiguousarray(audio))
            stream.accept_waveform(sample_rate, np.zeros(int(0.5 * sample_rate), dtype=np.float32))
            stream.input_finished()
            while recognizer.is_ready(stream):
                recognizer.decode_stream(stream)
            result = recognizer.get_result_all(stream)
            elapsed = time.perf_counter() - started
            record = {
                "sample_id": sample["id"],
                "model": "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20-encoder-int8",
                "mode": "hotwords" if args.hotwords else "baseline",
                "text": result.text.strip(),
                "audio_seconds": sample["duration"],
                "inference_seconds": elapsed,
                "rtf": elapsed / sample["duration"],
                "load_seconds": load_seconds,
                "peak_rss_mb": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 * 1024),
                "pid": os.getpid(),
            }
            out.write(json.dumps(record, ensure_ascii=False) + "\n")
            out.flush()
            print(f"{sample['id']}: {elapsed:.3f}s RTF={record['rtf']:.3f} {record['text']}", flush=True)


if __name__ == "__main__":
    main()
