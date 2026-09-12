from __future__ import annotations

import argparse
import json
import os
import subprocess
import threading
import time
from pathlib import Path

import psutil


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--hotwords", action="store_true")
    parser.add_argument("--port", type=int, default=18080)
    args = parser.parse_args()
    samples = json.loads(args.manifest_json.read_text(encoding="utf-8"))
    server_log_path = args.output.parent / "server.log"
    server_log = server_log_path.open("w", encoding="utf-8")
    command = [
        str(args.runtime), "serve", "--asr-model", str(args.model),
        "--device", "metal", "--host", "127.0.0.1", "--port", str(args.port),
        "--threads", "1", "--no-ui",
    ]
    started = time.perf_counter()
    server = subprocess.Popen(command, stdout=server_log, stderr=subprocess.STDOUT, text=True)
    process = psutil.Process(server.pid)
    peak_rss = 0
    stop_monitor = False

    def monitor() -> None:
        nonlocal peak_rss
        while not stop_monitor:
            try:
                peak_rss = max(peak_rss, process.memory_info().rss)
            except psutil.Error:
                return
            time.sleep(0.02)

    monitor_thread = threading.Thread(target=monitor, daemon=True)
    monitor_thread.start()
    try:
        health = subprocess.run(
            [str(args.runtime), "health", "--url", f"http://127.0.0.1:{args.port}/ready", "--wait", "60", "--quiet"],
            capture_output=True,
            text=True,
        )
        if health.returncode != 0:
            raise RuntimeError(f"NeMo server failed to become ready: {health.stderr}")
        load_seconds = time.perf_counter() - started
        with args.output.open("w", encoding="utf-8") as out:
            for sample in samples:
                curl_command = [
                    "curl", "-fsS", f"http://127.0.0.1:{args.port}/v1/audio/transcriptions",
                    "-F", f"file=@{sample['audio']}",
                    "-F", "response_format=json",
                ]
                if args.hotwords and sample.get("hotwords"):
                    contexts = json.dumps([{"phrases": sample["hotwords"], "boost": 3.0}], ensure_ascii=False)
                    curl_command += ["-F", f"speech_contexts={contexts}"]
                cpu_before = process.cpu_times()
                request_started = time.perf_counter()
                response = subprocess.run(curl_command, check=True, capture_output=True, text=True)
                elapsed = time.perf_counter() - request_started
                cpu_after = process.cpu_times()
                payload = json.loads(response.stdout)
                cpu_seconds = (cpu_after.user + cpu_after.system) - (cpu_before.user + cpu_before.system)
                record = {
                    "sample_id": sample["id"],
                    "model": "nemotron-3.5-asr-streaming-0.6b-q8",
                    "mode": "hotwords" if args.hotwords else "baseline",
                    "text": payload.get("text", "").strip(),
                    "audio_seconds": sample["duration"],
                    "inference_seconds": elapsed,
                    "rtf": elapsed / sample["duration"],
                    "load_seconds": load_seconds,
                    "peak_rss_mb": peak_rss / (1024 * 1024),
                    "cpu_seconds": cpu_seconds,
                    "cpu_utilization_cores": cpu_seconds / elapsed if elapsed else 0,
                    "pid": os.getpid(),
                }
                out.write(json.dumps(record, ensure_ascii=False) + "\n")
                out.flush()
                print(f"{sample['id']}: {elapsed:.3f}s RTF={record['rtf']:.3f} {record['text']}", flush=True)
    finally:
        stop_monitor = True
        monitor_thread.join(timeout=1)
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
        server_log.close()


if __name__ == "__main__":
    main()
