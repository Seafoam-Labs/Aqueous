#!/usr/bin/env python3
"""Exercise the real CLI's build gate and worker dispatch without a desktop."""
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
    env = dict(os.environ, PATH=directory)
    worker = root / ("aqueous-welcome-" + instance.removeprefix("aqueous-"))
    worker.write_text('#!/bin/sh\n'
                      f'if [ "$2" = shell-switch-capability ]; then printf "shell-switch-v1 {instance}\\n"; exit 0; fi\n'
                      '[ "$1" = --worker ] && [ "$2" = switch-shell ] || exit 97\n'
                      'printf \'{"ok":true,"shell":"%s"}\\n\' "$3"\n')
    worker.chmod(0o755)

    def run(*args):
        return subprocess.run([binary, *args], env=env, capture_output=True, text=True, timeout=10)

    help_result = run()
    if instance == "aqueous":
        assert "shell switch" not in help_result.stderr
        result = run("shell", "switch", "pearl", "--json")
        assert result.returncode != 0 and '"ok":true' not in result.stdout
    else:
        assert "shell switch" in help_result.stderr
        for shell in ("pearl", "dms", "noctalia"):
            result = run("shell", "switch", shell, "--json")
            assert result.returncode == 0, result
            assert json.loads(result.stdout) == {"ok": True, "shell": shell}
        for args in (("--json",), ("none", "--json"), ("pearl", "extra", "--json")):
            result = run("shell", "switch", *args)
            assert result.returncode == 2, result
            assert json.loads(result.stdout)["ok"] is False
        result = run("shell", "switch")
        assert result.returncode == 2
        # An older worker delegates unknown commands to session-runtime.sh.
        # Reproduce the reported error and ensure no switch is attempted.
        marker = root / "switch-attempted"
        worker.write_text('#!/bin/sh\n'
                          f'[ "$2" != switch-shell ] || : > "{marker}"\n'
                          'echo "Aqueous-Git session: Usage: session-runtime.sh selection|active-selection|prepare-session|condition SHELL|external-condition|action NAME|recover" >&2\nexit 1\n')
        for flags in ((), ("--json",)):
            result = run("shell", "switch", "dms", *flags)
            assert result.returncode == 1
            message = json.loads(result.stdout)["message"] if flags else result.stderr
            assert worker.name in message and "Rebuild/update" in message
            assert "session-runtime.sh" not in message
            assert not marker.exists()
        worker.write_text('#!/bin/sh\nprintf "shell-switch-v1 aqueous\\n"\n')
        result = run("shell", "switch", "pearl", "--json")
        assert result.returncode == 1 and json.loads(result.stdout)["ok"] is False
        worker.unlink()
        result = run("shell", "switch", "pearl", "--json")
        assert result.returncode == 1
        assert json.loads(result.stdout)["ok"] is False
print(f"PASS: {instance} shell-switch CLI availability, parsing, and worker dispatch")
