#!/usr/bin/env python3
"""Retired shell switching reports manual selection without launching Welcome."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
instance = sys.argv[2]
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    marker = root / "worker-called"
    worker = root / ("aqueous-welcome-" + instance.removeprefix("aqueous-"))
    worker.write_text(f'#!/bin/sh\n/usr/bin/touch "{marker}"\n')
    worker.chmod(0o755)
    env = dict(os.environ, PATH=directory)

    def run(*args):
        return subprocess.run([binary, *args], env=env, capture_output=True, text=True, timeout=10)

    assert "shell switch" not in run().stderr
    for shell in ("pearl", "dms", "noctalia", "none"):
        for flags in ((), ("--json",)):
            result = run("shell", "switch", shell, *flags)
            assert result.returncode == 2, result
            if flags:
                output = json.loads(result.stdout)
                assert output["ok"] is False
                message = output["message"]
            else:
                message = result.stderr
            assert f"{instance}/session.toml" in message
            assert "log out and back in" in message
    assert not marker.exists(), "Retired Welcome worker was invoked"
print(f"PASS: {instance} shell selection guidance without Welcome dispatch")
