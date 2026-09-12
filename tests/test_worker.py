from __future__ import annotations

import io
import json
import subprocess
import sys
import wave
from pathlib import Path

import pytest

from voice_input.adapter import (
    HotwordTokenBudgetError,
    MockAdapter,
    QwenMLXAdapter,
    audio_has_signal,
    format_hotword_prompt,
)
from voice_input.worker import ProtocolError, serve, validate_request


def test_validate_request_rejects_file_outside_session_root(tmp_path: Path) -> None:
    outside = tmp_path.parent / "private.wav"
    outside.touch()
    with pytest.raises(ProtocolError):
        validate_request({"v": 1, "type": "transcribe", "request_id": "r",
                          "audio_path": str(outside), "hotwords": []}, tmp_path)


def test_serve_preserves_utf8_and_escaped_newlines(tmp_path: Path) -> None:
    audio = tmp_path / "声音.wav"
    audio.touch()

    class Adapter:
        def transcribe(self, audio_path: Path, hotwords: list[str]):
            return "第一行\n第二行", "Chinese"

    request = {"v": 1, "type": "transcribe", "request_id": "abc",
               "audio_path": str(audio), "hotwords": ["派蒙"]}
    output = io.StringIO()
    serve(Adapter(), tmp_path, output, io.StringIO(json.dumps(request, ensure_ascii=False) + "\n"))
    frames = [json.loads(line) for line in output.getvalue().splitlines()]
    assert frames[0]["type"] == "ready"
    assert frames[1]["text"] == "第一行\n第二行"


def test_bad_message_returns_structured_error(tmp_path: Path) -> None:
    output = io.StringIO()
    serve(MockAdapter(), tmp_path, output, io.StringIO("not-json\n"))
    frames = [json.loads(line) for line in output.getvalue().splitlines()]
    assert frames[-1]["code"] == "BAD_REQUEST"


def test_hotword_budget_is_rejected_without_truncation(tmp_path: Path) -> None:
    audio = tmp_path / "voice.wav"; audio.touch()
    with pytest.raises(ProtocolError, match="budget"):
        validate_request({"v": 1, "type": "transcribe", "request_id": "r",
                          "audio_path": str(audio), "hotwords": ["词"] * 129}, tmp_path)


def test_conservative_silence_check_keeps_quiet_nonzero_audio(tmp_path: Path) -> None:
    silence = tmp_path / "silence.wav"; quiet = tmp_path / "quiet.wav"
    for path, frames in [(silence, b"\x00\x00" * 1600), (quiet, b"\x01\x00" * 1600)]:
        with wave.open(str(path), "wb") as target:
            target.setnchannels(1); target.setsampwidth(2); target.setframerate(16000); target.writeframes(frames)
    assert not audio_has_signal(silence)
    assert audio_has_signal(quiet)


def test_hotwords_use_qwen_recommended_vocabulary_format() -> None:
    assert format_hotword_prompt(["王天一", "Transformer", "USC", "南加大"]) == (
        "Vocabulary: 王天一, Transformer, USC, 南加大."
    )
    assert format_hotword_prompt([]) is None


def test_qwen_adapter_enforces_real_token_budget_and_normalizes_language(tmp_path: Path) -> None:
    audio = tmp_path / "voice.wav"
    with wave.open(str(audio), "wb") as target:
        target.setnchannels(1); target.setsampwidth(2); target.setframerate(16000); target.writeframes(b"\x01\x00")

    class Tokenizer:
        def encode(self, prompt: str): return list(range(len(prompt)))

    class Result:
        text = " 文本 "; language = ["Chinese"]

    class Model:
        _tokenizer = Tokenizer()
        kwargs: dict = {}
        def generate(self, *args, **kwargs):
            self.kwargs = kwargs
            return Result()

    adapter = QwenMLXAdapter.__new__(QwenMLXAdapter); adapter._model = Model()
    assert adapter.transcribe(audio, ["词"])[1] == "Chinese"
    assert adapter._model.kwargs["system_prompt"] == "Vocabulary: 词."
    assert "hotwords" not in adapter._model.kwargs
    with pytest.raises(HotwordTokenBudgetError): adapter.transcribe(audio, ["x" * 4097])


def test_mock_worker_subprocess_protocol(tmp_path: Path) -> None:
    audio = tmp_path / "short.wav"
    audio.touch()
    command = [sys.executable, "-m", "voice_input", "--mock", "--model-dir", str(tmp_path),
               "--session-root", str(tmp_path)]
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
    assert process.stdout and process.stdin
    ready = json.loads(process.stdout.readline())
    assert ready["sample_rate"] == 16000
    process.stdin.write(json.dumps({"v": 1, "type": "transcribe", "request_id": "r-1",
                                    "audio_path": str(audio), "hotwords": ["FastAPI"]}) + "\n")
    process.stdin.flush()
    result = json.loads(process.stdout.readline())
    assert result["request_id"] == "r-1"
    assert result["text"] == "mock:short [FastAPI]"
    process.stdin.close()
    assert process.wait(timeout=5) == 0
