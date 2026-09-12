from __future__ import annotations

from pathlib import Path
from typing import Protocol
import wave


class HotwordTokenBudgetError(ValueError):
    pass


def format_hotword_prompt(hotwords: list[str]) -> str | None:
    if not hotwords:
        return None
    return f"Vocabulary: {', '.join(hotwords)}."


def audio_has_signal(audio_path: Path) -> bool:
    """Reject only empty or exact digital silence; unknown formats remain eligible."""
    try:
        with wave.open(str(audio_path), "rb") as source:
            data = source.readframes(source.getnframes())
            if not data:
                return False
            if source.getsampwidth() == 1:
                return any(value != 128 for value in data)
            return any(data)
    except (EOFError, wave.Error):
        return True


class ASRAdapter(Protocol):
    def transcribe(self, audio_path: Path, hotwords: list[str]) -> tuple[str, str | None]: ...


class QwenMLXAdapter:
    """Thin product adapter around mlx-audio; deliberately independent of benchmark CLIs."""

    def __init__(self, model_dir: Path) -> None:
        from mlx_audio.stt import load_model

        self._model = load_model(model_dir)

    def transcribe(self, audio_path: Path, hotwords: list[str]) -> tuple[str, str | None]:
        if not audio_has_signal(audio_path):
            return "", None
        prompt = format_hotword_prompt(hotwords)
        if prompt:
            token_ids = self._model._tokenizer.encode(prompt)
            if len(token_ids) > 4096:
                raise HotwordTokenBudgetError("hotwords exceed 4096 tokenizer tokens")
        result = self._model.generate(
            str(audio_path), temperature=0.0, system_prompt=prompt
        )
        language = getattr(result, "language", None)
        if isinstance(language, (list, tuple)):
            language = language[0] if language else None
        return result.text.strip(), str(language) if language is not None else None


class MockAdapter:
    """Deterministic adapter for protocol tests; never used unless explicitly requested."""

    def transcribe(self, audio_path: Path, hotwords: list[str]) -> tuple[str, str | None]:
        return f"mock:{audio_path.stem}" + (f" [{','.join(hotwords)}]" if hotwords else ""), "Mock"
