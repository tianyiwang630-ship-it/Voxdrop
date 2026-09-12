from __future__ import annotations

import subprocess

from benchmark.common import load_manifest


def main() -> None:
    for sample in load_manifest():
        source = sample["audio_path"]
        target = sample["prepared_path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", str(source), "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(target)],
            check=True,
        )
        print(f"prepared {sample['id']}: {target.relative_to(target.parents[2])}")


if __name__ == "__main__":
    main()
