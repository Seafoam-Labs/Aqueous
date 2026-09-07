#!/usr/bin/env python3
# SPDX-FileCopyrightText: © 2026 Seafoam Labs
# SPDX-License-Identifier: GPL-3.0-only
"""Record a live focus-loss slowdown without changing the compositor or game."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
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
                                   errors="replace", timeout=2)
        result.update(status="ok" if completed.returncode == 0 else "error",
                      returncode=completed.returncode, stderr=completed.stderr)
        try:
            result["data"] = json.loads(completed.stdout)
        except ValueError:
            result["stdout"] = completed.stdout
    except subprocess.TimeoutExpired:
        result["status"] = "timeout"
    except OSError as error:
        result.update(status="error", error=str(error))
    result["duration_ms"] = round((time.monotonic() - started) * 1000, 3)
    return result


def pressure():
    result = {}
    for resource in ("cpu", "memory", "io"):
        try:
            result[resource] = Path(f"/proc/pressure/{resource}").read_text()
        except OSError:
            pass
    try:
        result["memory"] = {
            "pressure": result.get("memory"),
            "available": [line for line in Path("/proc/meminfo").read_text().splitlines()
                          if line.startswith(("MemAvailable:", "SwapFree:", "SwapTotal:"))],
        }
    except OSError:
        pass
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--duration", type=int, default=30, help="capture seconds (1–600; default 30)")
    parser.add_argument("--ctl", default=os.environ.get("AQUEOUSCTL_BIN", "aqueousctl"),
                        help="aqueousctl executable")
    args = parser.parse_args()
    if not 1 <= args.duration <= 600:
        parser.error("--duration must be between 1 and 600 seconds")
    ctl = shutil.which(args.ctl)
    if not ctl:
        parser.error("aqueousctl was not found; use --ctl /path/to/aqueousctl")

    commands = {
        "outputs": [ctl, "outputs", "--json"],
        "windows": [ctl, "windows", "--json"],
    }
    nvidia = shutil.which("nvidia-smi")
    if nvidia:
        commands["nvidia"] = [nvidia,
            "--query-gpu=index,name,driver_version,pstate,utilization.gpu,memory.used,memory.total,clocks.gr,clocks.mem",
            "--format=csv"]

    base = Path(tempfile.mkdtemp(prefix="aqueous-focus-stall-"))
    metadata = {
        "started_at": timestamp(), "kernel": platform.release(),
        "duration_seconds": args.duration, "commands": commands,
        "query_timeout_seconds": 2,
        "note": "Query durations measure compositor/driver responsiveness, not rendered FPS. "
                "Outputs report configured modes, not instantaneous VRR scanout frequency.",
    }
    (base / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Recording for {args.duration}s to {base}", flush=True)
    print("Focus the game for 5s, switch to the other monitor for 10s, then return to the game.", flush=True)

    failures = {name: 0 for name in commands}
    maximum_ms = {name: 0 for name in commands}
    sample_count = 0
    started = time.monotonic()
    interrupted = False
    with ThreadPoolExecutor(max_workers=len(commands)) as executor, (base / "samples.jsonl").open("w") as file:
        try:
            while time.monotonic() - started < args.duration:
                tick = time.monotonic()
                sample = {"timestamp": timestamp(), "elapsed_seconds": round(tick - started, 3)}
                # A slow driver query must not delay starting the compositor queries.
                pending = {name: executor.submit(query, command) for name, command in commands.items()}
                sample["system"] = pressure()
                for name, future in pending.items():
                    value = future.result()
                    sample[name] = value
                    failures[name] += value["status"] != "ok"
                    maximum_ms[name] = max(maximum_ms[name], value["duration_ms"])
                file.write(json.dumps(sample) + "\n")
                file.flush()
                sample_count += 1
                time.sleep(max(0, min(tick + 1, started + args.duration) - time.monotonic()))
        except KeyboardInterrupt:
            interrupted = True

    summary = {"finished_at": timestamp(), "samples": sample_count, "interrupted": interrupted,
               "failed_queries": failures, "maximum_query_ms": maximum_ms}
    (base / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"Saved {sample_count} samples to {base}")
    print("Include the game/Proton versions and the approximate time the slowdown started with the capture.")


if __name__ == "__main__":
    main()
