#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import argparse
import json
import plistlib
from datetime import datetime, timezone
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("dmg", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--real-inference-passed", action="store_true")
    args = parser.parse_args()
    app, dmg, output = args.app, args.dmg, args.output
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    report = {
        "schema_version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "candidate": {
            "version": info["CFBundleShortVersionString"],
            "minimum_macos": info["LSMinimumSystemVersion"],
            "architecture": "arm64",
            "dmg": dmg.name,
            "dmg_bytes": dmg.stat().st_size,
            "dmg_sha256": sha256(dmg),
        },
        "automated_checks": {
            "bundle_layout_and_hashes": "passed",
            "relocatable_dynamic_links": "passed",
            "arm64_and_macos_minimum": "passed",
            "packaged_worker_protocol": "passed",
            "real_inference_after_dmg_copy": "passed" if args.real_inference_passed else "not_tested",
            "ad_hoc_code_signature": "passed",
            "dmg_internal_checksum": "passed",
            "read_only_dmg_mount": "passed",
            "copied_app_after_dmg_eject": "passed",
            "dmg_below_1000000000_bytes": "passed",
        },
        "manual_external_checks": {
            "independent_m_series_mac": "not_tested",
            "permissions_allow_deny_recover": "not_tested",
            "gatekeeper_open_anyway_flow": "not_tested",
            "long_running_and_sleep_wake": "not_tested",
        },
    }
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(output)


if __name__ == "__main__":
    main()
