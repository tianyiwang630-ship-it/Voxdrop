from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Any, TextIO

from . import MODEL_ID, PROTOCOL_VERSION
from .adapter import HotwordTokenBudgetError, MockAdapter, QwenMLXAdapter

MAX_MESSAGE_BYTES = 1_048_576
MAX_HOTWORDS = 128
MAX_HOTWORD_CHARS = 16_384


class ProtocolError(ValueError):
    pass


def _inside(path: Path, root: Path) -> bool:
    try:
        path.resolve(strict=True).relative_to(root.resolve(strict=True))
        return True
    except (FileNotFoundError, ValueError):
        return False


def validate_request(raw: Any, session_root: Path) -> tuple[str, Path, list[str]]:
    if not isinstance(raw, dict) or raw.get("v") != PROTOCOL_VERSION:
        raise ProtocolError("unsupported protocol version")
    if raw.get("type") != "transcribe":
        raise ProtocolError("unsupported message type")
    request_id = raw.get("request_id")
    audio_value = raw.get("audio_path")
    hotwords = raw.get("hotwords", [])
    if not isinstance(request_id, str) or not request_id or len(request_id) > 128:
        raise ProtocolError("invalid request_id")
    if not isinstance(audio_value, str) or not audio_value:
        raise ProtocolError("invalid audio_path")
    audio_path = Path(audio_value)
    if not audio_path.is_absolute() or not _inside(audio_path, session_root):
        raise ProtocolError("audio_path is outside the session directory")
    if not isinstance(hotwords, list) or any(not isinstance(word, str) for word in hotwords):
        raise ProtocolError("hotwords must be a string array")
    cleaned = [word.strip() for word in hotwords if word.strip()]
    if len(cleaned) > MAX_HOTWORDS or sum(len(word) for word in cleaned) > MAX_HOTWORD_CHARS:
        raise ProtocolError("hotword budget exceeded")
    return request_id, audio_path, cleaned


def emit(stream: TextIO, payload: dict[str, Any]) -> None:
    stream.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
    stream.flush()


def serve(adapter: Any, session_root: Path, protocol_out: TextIO, input_stream: TextIO) -> None:
    emit(
        protocol_out,
        {"v": PROTOCOL_VERSION, "type": "ready", "model_id": MODEL_ID, "sample_rate": 16000},
    )
    for line in input_stream:
        if len(line.encode("utf-8")) > MAX_MESSAGE_BYTES:
            emit(protocol_out, {"v": 1, "type": "error", "request_id": None,
                                "code": "MESSAGE_TOO_LARGE", "message": "请求过大", "retryable": False})
            continue
        request_id: str | None = None
        try:
            raw = json.loads(line)
            request_id, audio_path, hotwords = validate_request(raw, session_root)
            started = time.perf_counter()
            text, language = adapter.transcribe(audio_path, hotwords)
            emit(protocol_out, {"v": 1, "type": "result", "request_id": request_id,
                                "text": text.strip(), "language": language,
                                "inference_ms": round((time.perf_counter() - started) * 1000)})
        except HotwordTokenBudgetError:
            emit(protocol_out, {"v": 1, "type": "error", "request_id": request_id,
                                "code": "HOTWORD_BUDGET_EXCEEDED", "message": "热词超过 4096 tokenizer tokens", "retryable": False})
        except (ProtocolError, json.JSONDecodeError) as exc:
            emit(protocol_out, {"v": 1, "type": "error", "request_id": request_id,
                                "code": "BAD_REQUEST", "message": str(exc), "retryable": False})
        except Exception as exc:  # avoid leaking audio paths, text, or hotwords
            print(f"inference failure: {type(exc).__name__}", file=sys.stderr, flush=True)
            emit(protocol_out, {"v": 1, "type": "error", "request_id": request_id,
                                "code": "INFERENCE_FAILED", "message": "本地识别失败", "retryable": True})


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--session-root", type=Path, required=True)
    parser.add_argument("--mock", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    args.session_root.mkdir(parents=True, exist_ok=True)

    # Preserve the original stdout pipe for protocol frames, then make fd 1 diagnostic-only.
    # This prevents imports/native libraries from corrupting JSON Lines framing.
    protocol_out = os.fdopen(os.dup(sys.stdout.fileno()), "w", encoding="utf-8", buffering=1)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    sys.stdout = sys.stderr
    try:
        adapter = MockAdapter() if args.mock else QwenMLXAdapter(args.model_dir.resolve(strict=True))
    except Exception as exc:
        print(f"model load failure: {type(exc).__name__}", file=sys.stderr, flush=True)
        emit(protocol_out, {"v": 1, "type": "error", "request_id": None,
                            "code": "MODEL_LOAD_FAILED", "message": "本地模型加载失败", "retryable": True})
        raise SystemExit(2)
    serve(adapter, args.session_root, protocol_out, sys.stdin)


if __name__ == "__main__":
    main()
