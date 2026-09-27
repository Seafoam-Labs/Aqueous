#!/usr/bin/env python3
"""Exercise the real standalone GTK picker on an isolated Broadway display."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

picker = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="aqueous-picker-test-") as temporary:
    root = Path(temporary)
    runtime = root / "run"
    runtime.mkdir(mode=0o700)
    env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), GDK_BACKEND="broadway",
               BROADWAY_DISPLAY=":37", GSK_RENDERER="cairo", GTK_A11Y="none",
               GTK_USE_PORTAL="0", GIO_USE_VFS="local", GSETTINGS_BACKEND="memory",
               AQUEOUS_PICKER_TEST_CLOSE_MS="100")
    env.pop("AQUEOUS_PICKER_TEST_CHOOSE_INDEX", None)
    # Invalid/empty source lists must finish without a GUI or any shell helper.
    for source, ok in [(b"", True), (b"\n\n", True), (b"bad\0source\n", False),
                       (b"x" * (1024 * 1024 + 1), False)]:
        result = subprocess.run([str(picker)], input=source, capture_output=True, env=env, timeout=10)
        assert (result.returncode == 0) == ok, result.stderr
        assert result.stdout == b"", result.stdout

    # No service directories: GTK must not activate host desktop services.
    bus_config = root / "bus.conf"
    bus_config.write_text(f'''<busconfig><type>session</type>
<listen>unix:path={root / 'bus'}</listen><auth>EXTERNAL</auth>
<policy context="default"><allow user="*"/><allow own="*"/>
<allow send_destination="*"/><allow receive_sender="*"/></policy></busconfig>''')
    bus = subprocess.Popen(["dbus-daemon", f"--config-file={bus_config}", "--nofork", "--print-address=1"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    env["DBUS_SESSION_BUS_ADDRESS"] = bus.stdout.readline().strip()
    assert env["DBUS_SESSION_BUS_ADDRESS"], bus.stderr.read()
    display = subprocess.Popen(["gtk4-broadwayd", f"--unixsocket={root / 'http'}", ":37"],
                               env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 10
        while not list(runtime.glob("broadway*.socket")):
            assert display.poll() is None, display.stderr.read()
            assert time.monotonic() < deadline, "Broadway startup timeout"
            time.sleep(0.05)
        source = "Monitor: HEADLESS-1\nWindow: Test %s — UTF-8\n".encode()
        for index, expected in [("1", source.splitlines(keepends=True)[1]),
                                (None, b""), ("99", b"")]:
            request_env = dict(env)
            if index is not None:
                request_env["AQUEOUS_PICKER_TEST_CHOOSE_INDEX"] = index
            result = subprocess.run([str(picker)], input=source, capture_output=True,
                                    env=request_env, timeout=10)
            assert result.returncode == 0, result.stderr
            assert result.stdout == expected, (index, result.stdout, result.stderr)
        print("PASS: standalone GTK picker selection, cancellation, exact source output and input limits")
    finally:
        display.terminate()
        display.wait(timeout=5)
        bus.terminate()
        bus.wait(timeout=5)
