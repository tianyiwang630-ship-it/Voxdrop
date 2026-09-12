from __future__ import annotations

import json
from pathlib import Path

from benchmark.common import ROOT, load_manifest

RUNS = {
    "faster-whisper Base INT8": ("baseline_faster_whisper_cached", "hotwords_faster_whisper"),
    "Qwen3-ASR 0.6B MLX 4bit": ("baseline_qwen3_mlx_4bit_peakmem", "hotwords_qwen3_mlx_4bit"),
    "SeACo-Paraformer backbone INT8": ("baseline_seaco_paraformer_int8_v2", "hotwords_seaco_paraformer_int8_v2"),
    "Sherpa Zipformer zh-en encoder INT8": ("baseline_sherpa_encoder_int8", "hotwords_sherpa_encoder_int8_v2"),
    "Nemotron 3.5 ASR 0.6B Q8": ("baseline_nemotron_q8_current", "hotwords_nemotron_q8_current"),
}

COMPUTE = {
    "faster-whisper Base INT8": "CPU / CTranslate2 INT8",
    "Qwen3-ASR 0.6B MLX 4bit": "Metal / MLX 4bit",
    "SeACo-Paraformer backbone INT8": "CPU / ONNX Runtime, 4 threads",
    "Sherpa Zipformer zh-en encoder INT8": "CPU / ONNX Runtime, 4 threads",
    "Nemotron 3.5 ASR 0.6B Q8": "Metal / GGML Q8",
}


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def read_predictions(run_name: str):
    path = ROOT / "results" / run_name / "predictions.jsonl"
    return {x["sample_id"]: x for x in (json.loads(line) for line in path.read_text(encoding="utf-8").splitlines())}


def cell(value: object) -> str:
    return str(value).replace("|", "\\|").replace("\n", "<br>")


def size_mb(paths: list[Path]) -> float:
    total = 0
    seen = set()
    for base in paths:
        for path in ([base] if base.is_file() else base.rglob("*")):
            if not path.is_file():
                continue
            stat = path.stat()
            identity = (stat.st_dev, stat.st_ino)
            if identity not in seen:
                seen.add(identity)
                total += stat.st_size
    return total / 1024**2


def deployed_sizes() -> dict[str, float]:
    sherpa = ROOT / "models/sherpa/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20"
    return {
        "faster-whisper Base INT8": size_mb([ROOT / "models/faster-whisper"]),
        "Qwen3-ASR 0.6B MLX 4bit": size_mb([ROOT / "models/qwen3-asr/Qwen3-ASR-0.6B-4bit"]),
        "SeACo-Paraformer backbone INT8": size_mb([ROOT / "models/funasr/seaco-paraformer-contextual-onnx"]),
        "Sherpa Zipformer zh-en encoder INT8": size_mb([sherpa / name for name in [
            "encoder-epoch-99-avg-1.int8.onnx", "decoder-epoch-99-avg-1.onnx",
            "joiner-epoch-99-avg-1.onnx", "tokens.txt", "bpe.model", "bpe.vocab",
        ]]),
        "Nemotron 3.5 ASR 0.6B Q8": size_mb([ROOT / "models/nemotron/current/nemotron-3.5-asr-streaming-0.6b.q8_0.gguf"]),
    }


def main() -> None:
    metrics = {}
    predictions = {}
    for model, (baseline, hotword) in RUNS.items():
        metrics[(model, "baseline")] = read_json(ROOT / "results" / baseline / "metrics.json")
        metrics[(model, "hotwords")] = read_json(ROOT / "results" / hotword / "metrics.json")
        predictions[(model, "baseline")] = read_predictions(baseline)
        predictions[(model, "hotwords")] = read_predictions(hotword)
    sizes = deployed_sizes()
    samples = load_manifest()

    lines = [
        "# PC 语音输入法 ASR 统一 Benchmark 报告",
        "",
        "> 评测日期：2026-09-11；设备：Apple A18 Pro、8GB 统一内存、macOS 26.4；数据：10 条、5 个场景、共 227.256 秒。",
        "",
        "## 结论",
        "",
        "**建议将 Qwen3-ASR 0.6B MLX 4bit 作为 Apple Silicon 版 MVP 的首选 ASR，SeACo-Paraformer 作为 CPU 高吞吐备选。**",
        "",
        "Qwen 在这套数据上的基础 MER 为 2.64%，为所有模型最低；中英混输和长句 MER 均为 0%。加入 Domain Vocabulary 后，热词召回率从 75.0% 提升到 87.5%，整体 MER 降到 2.26%。其主要代价是约 1.42GB Metal 峰值内存，且 MLX 路线只能直接覆盖 Apple Silicon。",
        "",
        "SeACo 的整体 MER 为 5.40%，是最快的模型（RTF 0.023），但峰值 RSS 约 1.29GB，不轻。当前 funasr-onnx 接口对单个热词有 10 字符上限，本数据的英文热词召回率没有提升，因此现阶段不适合直接承担产品的个性化词汇卖点。",
        "",
        "Sherpa 部署文件最小（约 202MB）、内存最低（约 428MB），但英文和专业词明显弱于 Qwen/SeACo，而且旧双语 checkpoint 的 token 表无法编码大部分专业英文热词。Nemotron 的新 revision 可以做真正的 Word Boosting，但启动约 41–44 秒、峰值 RSS 约 1.68GB，且基础 MER 11.81%，不建议成为当前 MVP 主模型。faster-whisper Base 的热词提示很强，但中文长录音出现重复性幻觉，基础 MER 18.09%，仅适合保留为 baseline。",
        "",
        "## 基础准确率与性能",
        "",
        "| 模型 | MER↓ | 中文 | 英文 | 混输 | 专业词 | 长句 | RTF↓ | 总推理时间 |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for model in RUNS:
        m = metrics[(model, "baseline")]
        scene = m["scenes"]
        lines.append(
            f"| {model} | {m['overall_mer']*100:.2f}% | {scene['daily_zh']['error_rate']*100:.2f}% | "
            f"{scene['daily_en']['error_rate']*100:.2f}% | {scene['mixed']['error_rate']*100:.2f}% | "
            f"{scene['terminology']['error_rate']*100:.2f}% | {scene['long_sentence']['error_rate']*100:.2f}% | "
            f"{m['overall_rtf']:.3f} | {m['total_inference_seconds']:.2f}s |"
        )

    lines += [
        "",
        "中文列使用 CER 式单字 token，英文列使用 WER，其他场景使用“中文按字、英文按词”的 MER。所有指标忽略大小写和标点，但没有把“11”与“十一”作语义等价替换。",
        "",
        "## 热词 A/B",
        "",
        "| 模型 | 无热词召回 | 开热词召回 | 变化 | 无热词 MER | 开热词 MER | 结论 |",
        "|---|---:|---:|---:|---:|---:|---|",
    ]
    hotword_notes = {
        "faster-whisper Base INT8": "Hint 显著提升召回，但小幅伤害整体 MER",
        "Qwen3-ASR 0.6B MLX 4bit": "召回和整体准确率同时改善",
        "SeACo-Paraformer backbone INT8": "当前接口对长英文热词受限，没有收益",
        "Sherpa Zipformer zh-en encoder INT8": "多数英文词 OOV，且热词模式需要更慢的 beam search",
        "Nemotron 3.5 ASR 0.6B Q8": "Word Boosting 有效，但术语句仍有明显错词",
    }
    for model in RUNS:
        b, h = metrics[(model, "baseline")], metrics[(model, "hotwords")]
        delta = (h["hotword_recall"] - b["hotword_recall"]) * 100
        lines.append(
            f"| {model} | {b['hotword_recall']*100:.1f}% | {h['hotword_recall']*100:.1f}% | "
            f"{delta:+.1f}pp | {b['overall_mer']*100:.2f}% | {h['overall_mer']*100:.2f}% | {hotword_notes[model]} |"
        )

    lines += [
        "",
        "## 资源与工程指标",
        "",
        "| 模型 | 计算路线 | 部署体积 | 加载/就绪时间 | 峰值内存 | 延迟中位数 | 延迟 P95 | RTF P95 | 标点数量 F1* |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for model in RUNS:
        m = metrics[(model, "baseline")]
        memory = max(m["peak_rss_mb"], m.get("peak_metal_mb", 0))
        lines.append(
            f"| {model} | {COMPUTE[model]} | {sizes[model]:.0f}MB | {m['load_seconds']:.2f}s | "
            f"{memory:.0f}MB | {m['latency_median_seconds']:.2f}s | {m['latency_p95_seconds']:.2f}s | "
            f"{m['rtf_p95']:.3f} | {m['punctuation_count_f1']*100:.1f}% |"
        )
    lines += [
        "",
        "\* 标点数量 F1 只比较各类标点的数量，不验证具体落点，只用于区分“是否输出标点”，不是完整的标点准确率。Qwen 的内存值来自 MLX Metal peak memory；其他模型为进程峰值 RSS。Nemotron 就绪时间包括 Metal pipeline 编译与 runtime warm-up。",
        "",
        "## 逐条基础转录与耗时",
        "",
    ]
    for sample in samples:
        lines += [f"### {sample['id']} · {sample['scene']}", "", f"**参考文本：** {sample['reference_text']}", "", "| 模型 | 推理时间 | RTF | 转录文本 |", "|---|---:|---:|---|"]
        for model in RUNS:
            r = predictions[(model, "baseline")][sample["id"]]
            lines.append(f"| {model} | {r['inference_seconds']:.3f}s | {r['rtf']:.3f} | {cell(r['text'])} |")
        lines.append("")

    lines += ["## 专业词热词模式转录", ""]
    for sample_id in ["terms_01", "terms_02"]:
        sample = next(s for s in samples if s["id"] == sample_id)
        lines += [f"### {sample_id}", "", f"**热词：** {', '.join(sample.get('hotwords', []))}", "", "| 模型 | 推理时间 | 转录文本 |", "|---|---:|---|"]
        for model in RUNS:
            r = predictions[(model, "hotwords")][sample_id]
            lines.append(f"| {model} | {r['inference_seconds']:.3f}s | {cell(r['text'])} |")
        lines.append("")

    lines += [
        "## 局限与下一步产品决策",
        "",
        "- 本结论只覆盖当前 10 条、单一设备和当前录音人，用于 PoC 选型，不能外推为通用模型排名。",
        "- 现在可以做出 Apple Silicon 路线的决策：优先围绕 Qwen 做输入法 PoC。",
        "- Windows 不能直接使用 MLX，因此在定最终 MVP 之前，需验证 Qwen 的 Windows 推理路线，或接受 macOS 与 Windows 使用不同 runtime。",
        "- 如果必须单一 CPU 模型覆盖双平台，当前数据更支持 SeACo，但必须先解决英文热词长度限制，否则它与产品的核心差异化能力冲突。",
        "",
        "## 可复现性",
        "",
        "评测入口为 `python -m benchmark.run --backend <backend>`，数据清单在 `benchmark/manifest.yaml`，每次运行的原始转录保存在对应结果目录的 `predictions.jsonl`，汇总指标保存在 `metrics.json`。",
    ]
    output = ROOT / "results" / "ASR_Benchmark报告.md"
    output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(output)


if __name__ == "__main__":
    main()
