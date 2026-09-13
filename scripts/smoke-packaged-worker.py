#!/usr/bin/env python3
"""Exercise the JSON-lines worker using only files inside a packaged app."""

from __future__ import annotations

import argparse
import json
import os
import selectors
import shutil
import struct
import subprocess
import tempfile
import time
import uuid
import wave
from pathlib import Path


def read_frame(process: subprocess.Popen[str], timeout: float) -> dict[str, object]:
    selector = selectors.DefaultSelector()
    assert process.stdout is not None
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout
    try:
        while time.monotonic() < deadline:
            if process.poll() is not None:
                stderr = process.stderr.read() if process.stderr else ""
                raise RuntimeError(f"worker exited with {process.returncode}: {stderr[-2000:]}")
            events = selector.select(min(0.25, deadline - time.monotonic()))
            if not events:
                continue
            line = process.stdout.readline()
            if line:
                return json.loads(line)
        raise TimeoutError("timed out waiting for worker protocol frame")
    finally:
        selector.close()


def make_wav(path: Path) -> None:
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(16_000)
        frames = [int(1200 * ((index % 32) - 16) / 16) for index in range(3200)]
        output.writeframes(b"".join(struct.pack("<h", sample) for sample in frames))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--real-audio", type=Path)
    parser.add_argument("--startup-timeout", type=float, default=180)
    args = parser.parse_args()

    app = args.app.resolve(strict=True)
    resources = app / "Contents/Resources"
    python = resources / "runtime/bin/python3.11"
    model = resources / "models/qwen3-asr/Qwen3-ASR-0.6B-4bit"
    if not python.is_file() or not os.access(python, os.X_OK) or not model.is_dir():
        raise SystemExit("packaged runtime/model is incomplete")

    with tempfile.TemporaryDirectory(prefix="voxdrop-packaged-worker-") as raw_session:
        session = Path(raw_session)
        audio = session / "smoke.wav"
        if args.real_audio:
            shutil.copy2(args.real_audio.resolve(strict=True), audio)
        else:
            make_wav(audio)
        environment = {
            "HOME": str(session / "home"),
            "TMPDIR": str(session),
            "PATH": "/usr/bin:/bin",
            "HF_HUB_OFFLINE": "1",
            "TRANSFORMERS_OFFLINE": "1",
            "PYTHONNOUSERSITE": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "TOKENIZERS_PARALLELISM": "false",
        }
        Path(environment["HOME"]).mkdir()
        command = [
            str(python), "-I", "-B", "-u", "-m", "voice_input",
            "--model-dir", str(model), "--session-root", str(session),
        ]
        if args.real_audio is None:
            command.append("--mock")
        process = subprocess.Popen(
            command,
            cwd=resources,
            env=environment,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        try:
            ready = read_frame(process, args.startup_timeout)
            if ready.get("type") != "ready":
                raise RuntimeError(f"expected ready frame, got: {ready}")
            request_id = str(uuid.uuid4())
            request = {
                "v": 1,
                "type": "transcribe",
                "request_id": request_id,
                "audio_path": str(audio),
                "hotwords": ["言落"],
                "language": None,
            }
            assert process.stdin is not None
            process.stdin.write(json.dumps(request, ensure_ascii=False) + "\n")
            process.stdin.flush()
            result = read_frame(process, 180)
            if result.get("type") != "result" or result.get("request_id") != request_id:
                raise RuntimeError(f"unexpected result frame: {result}")
            if args.real_audio is not None and not str(result.get("text", "")).strip():
                raise RuntimeError("real packaged inference returned empty text")
            print(json.dumps({"status": "passed", "mode": "real" if args.real_audio else "mock",
                              "result": result}, ensure_ascii=False))
        finally:
            if process.stdin:
                process.stdin.close()
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


if __name__ == "__main__":
    main()
