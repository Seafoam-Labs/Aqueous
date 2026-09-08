#!/usr/bin/env python3
# SPDX-FileCopyrightText: © 2026 Seafoam Labs
# SPDX-License-Identifier: GPL-3.0-only
"""Record window/output/scene state while reproducing a live hide/show failure.

Does not move focus, change configuration, or request screenshots/rendering.
Snapshots are independent read-only queries, not an atomic compositor snapshot.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def query(command):
    started = time.monotonic()
    result = {"started_at": timestamp()}
    try:
        completed = subprocess.run(command, capture_output=True, text=True,
                                   errors="replace", timeout=3)
        result.update(returncode=completed.returncode, stderr=completed.stderr,
                      status="ok" if completed.returncode == 0 else "error")
        try:
            result["data"] = json.loads(completed.stdout)
        except ValueError:
            result["text"] = completed.stdout
    except subprocess.TimeoutExpired:
        result["status"] = "timeout"
    except OSError as error:
        result.update(status="error", error=str(error))
    result["duration_ms"] = round((time.monotonic() - started) * 1000, 3)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ctl", default="aqueousctl")
    parser.add_argument("--duration", type=int, default=30)
    parser.add_argument("--interval", type=float, default=0.25)
    parser.add_argument("--match", default="discord", help="case-insensitive app/class/title substring")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not 1 <= args.duration <= 600 or not 0.1 <= args.interval <= 5:
        parser.error("duration must be 1–600 seconds and interval 0.1–5 seconds")
    ctl = shutil.which(args.ctl)
    if not ctl:
        parser.error("aqueousctl was not found; use --ctl /path/to/aqueousctl")
    directory = args.output or Path(tempfile.mkdtemp(prefix="aqueous-live-remap-"))
    directory.mkdir(parents=True, exist_ok=True)
    if (directory / "samples.jsonl").exists():
        parser.error("output already contains a recording")
    commands = {"scene": [ctl, "scene"], "windows": [ctl, "windows", "--json"],
                "outputs": [ctl, "outputs", "--json"]}
    metadata = {"started_at": timestamp(), "duration_seconds": args.duration,
                "interval_seconds": args.interval, "match": args.match, "commands": commands,
                "note": "Queries are not atomic. No screencopy or input changes are requested. "
                        "Logs contain window titles and display configuration."}
    (directory / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Recording to {directory}", flush=True)
    print("Close Discord on monitor 1, reopen it on monitor 2, and leave the failed state visible.", flush=True)
    started = time.monotonic()
    failures = {key: 0 for key in commands}
    timeline, previous, samples = [], None, 0
    interrupted = False
    match = args.match.casefold()
    with ThreadPoolExecutor(max_workers=3) as pool, (directory / "samples.jsonl").open("w") as file:
        try:
            while time.monotonic() - started < args.duration:
                tick = time.monotonic()
                pending = {key: pool.submit(query, cmd) for key, cmd in commands.items()}
                sample = {"timestamp": timestamp(), "elapsed_seconds": round(tick - started, 3)}
                for key, future in pending.items():
                    sample[key] = future.result()
                    failures[key] += sample[key]["status"] != "ok"
                file.write(json.dumps(sample) + "\n")
                file.flush()
                samples += 1
                window_data = sample["windows"].get("data", [])
                if not isinstance(window_data, list):
                    window_data = []
                targets = [w for w in window_data if any(
                    match in str(w.get(field) or "").casefold() for field in ("app_id", "class", "title"))]
                scene = sample["scene"].get("text", "")
                scene_lines = [line for line in scene.splitlines()
                               if "window:" in line and match in line.casefold()]
                state = {"windows": targets, "scene_window_lines": scene_lines,
                         "query_status": {key: sample[key]["status"] for key in commands}}
                if state != previous:
                    timeline.append({"elapsed_seconds": sample["elapsed_seconds"], **state})
                    previous = state
                time.sleep(max(0, min(tick + args.interval, started + args.duration) - time.monotonic()))
        except KeyboardInterrupt:
            interrupted = True
    summary = {"finished_at": timestamp(), "samples": samples, "interrupted": interrupted,
               "failed_queries": failures, "target_timeline": timeline}
    (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"Saved {samples} samples to {directory}; failed queries: {failures}", flush=True)
    return 1 if samples == 0 or any(count == samples for count in failures.values()) else 0


if __name__ == "__main__":
    raise SystemExit(main())
