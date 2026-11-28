#!/usr/bin/env python3
"""Regression for issue #135: swapping to an EMPTY workspace with a scrolling
layout must not reveal off-screen/peeking columns while the slide is in flight.

Three solid-color columns (red/green/blue) with green focused and centered, so
red and blue only peek at the output edges. Switching to an adjacent empty
workspace slides the outgoing strip; the whole visible strip must travel as a
rigid unit, so a neighbor's on-screen area never exceeds its resting peek, and
the settled empty workspace shows no window content at all.

Requires grim, wlrctl, Pillow and Wayland development tools. Runs a private
headless compositor. Artifacts are retained under the work dir on failure.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--compositor", type=Path, default=ROOT / "zig-out/bin/aqueous")
parser.add_argument("--ctl", type=Path, default=ROOT / "zig-out/bin/aqueousctl")
parser.add_argument("--renderer", choices=("vulkan", "pixman"), default="pixman")
args = parser.parse_args()

work = Path(tempfile.mkdtemp(prefix="aqueous-empty-scrolling-"))
runtime = work / "runtime"
runtime.mkdir(mode=0o700)
env = {k: v for k, v in os.environ.items()
       if not k.startswith(("AQUEOUS_", "WLR_", "DMS_"))
       and k not in ("WAYLAND_DISPLAY", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "LD_PRELOAD")}
env.update(XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / "config"),
           XDG_CACHE_HOME=str(work / "cache"), XDG_STATE_HOME=str(work / "state"),
           WLR_BACKENDS="headless", WLR_HEADLESS_OUTPUTS="1", WLR_RENDERER=args.renderer,
           AQUEOUS_DEBUG_WINDOW_STATE="1")
for name in ("config", "rules", "layout", "input", "outputs"):
    env["AQUEOUS_" + name.upper()] = str(work / (name + ".toml"))
(work / "config.toml").write_text('''[input]
focus_follows_mouse = false
[workspace_transition]
enabled = true
rate = 1.5
[keybinds]
focus_workspace_1 = "Super+1"
focus_workspace_2 = "Super+2"
''')
(work / "rules.toml").write_text("")


def run(command):
    return subprocess.check_output([str(a) for a in command], env=env, text=True,
                                   stderr=subprocess.PIPE, timeout=20)


protocols = Path(run(["pkg-config", "--variable=pkgdatadir", "wayland-protocols"]).strip())
xml = protocols / "stable/xdg-shell/xdg-shell.xml"
run(["wayland-scanner", "client-header", xml, work / "xdg-shell-client-protocol.h"])
run(["wayland-scanner", "private-code", xml, work / "xdg-shell-protocol.c"])
run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", f"-I{work}",
     ROOT / "scripts/fixtures/empty-scrolling-client.c", work / "xdg-shell-protocol.c",
     "-o", work / "client",
     *shlex.split(run(["pkg-config", "--cflags", "--libs", "wayland-client"]))])

processes, logs = [], []


def launch(command, name):
    log = (work / (name + ".log")).open("w")
    logs.append(log)
    p = subprocess.Popen([str(a) for a in command], env=env, stdout=log, stderr=log)
    processes.append(p)
    return p


def wait(predicate, message):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        assert all(p.poll() is None for p in processes), f"process exited: {work}"
        value = predicate()
        if value:
            return value
        time.sleep(.025)
    raise AssertionError(message)


ctl = args.ctl


def windows():
    return json.loads(run([ctl, "windows", "--json"]))


def workspace(n):
    run(["wlrctl", "keyboard", "type", str(n), "modifiers", "SUPER"])


def activate(win):
    run([ctl, "window", "activate", "--id", win["id"], "--json"])


def set_scrolling():
    run([ctl, "layout", "--output", "HEADLESS-1", "--set", "scrolling", "--json"])


def classify(r, g, b):
    if r > 150 and g < 90 and b < 90:
        return "red"
    if g > 130 and r < 90 and b < 110:
        return "green"
    if b > 160 and r < 100 and g < 130:
        return "blue"
    return None


def count_colors(path):
    with Image.open(path) as image:
        image = image.convert("RGB")
        counts = {"red": 0, "green": 0, "blue": 0}
        for n, (r, g, b) in image.getcolors(image.width * image.height):
            key = classify(r, g, b)
            if key:
                counts[key] += n
        return counts


def shot(name):
    path = work / name
    run(["grim", "-l", "0", path])
    return count_colors(path)


def sample(label, seconds):
    frames = []
    deadline = time.monotonic() + seconds
    n = 0
    while time.monotonic() < deadline:
        scene = run([ctl, "scene"])
        if "anim=true" not in scene:
            time.sleep(.01)
            continue
        counts = shot(f"{label}-{n:03}.png")
        frames.append(counts)
        n += 1
        time.sleep(.02)
    return frames


failures = []
try:
    launch([args.compositor.resolve(), "-no-xwayland", "-policy", "internal",
            "-log-level", "info", "-c", "true"], "compositor")
    socket = wait(lambda: next((p for p in runtime.glob("wayland-*") if p.is_socket()), None),
                  "no socket")
    env["WAYLAND_DISPLAY"] = socket.name
    wins = {}
    for name, color in (("left", "ffc82828"), ("mid", "ff28b446"), ("right", "ff325ad2")):
        launch([work / "client", "--color", color, "--app-id", f"empty-scrolling.{name}",
                "--title", name], f"client-{name}")
        wins[name] = wait(
            lambda: next((w for w in windows() if w["app_id"] == f"empty-scrolling.{name}"), None),
            f"{name} did not map")
        time.sleep(.3)
    time.sleep(.3)
    set_scrolling()
    time.sleep(.5)
    activate(wins["mid"])
    time.sleep(1.5)
    rest = shot("rest.png")

    # Switch to the later empty workspace: outgoing slides left, right/blue
    # neighbor must not be revealed.
    workspace(2)
    frames_a = sample("caseA", 7)
    time.sleep(.5)
    settled_a = shot("caseA-settled.png")

    # Move the columns to workspace 2 and switch to the earlier empty
    # workspace: outgoing slides right, left/red neighbor (the reported
    # symptom) must not be revealed.
    for name in wins:
        run([ctl, "window", "move", "--id", wins[name]["id"], "--workspace-id", "2", "--json"])
    workspace(2)
    time.sleep(.5)
    set_scrolling()
    time.sleep(.5)
    activate(wins["mid"])
    time.sleep(1.5)
    rest_b = shot("restB.png")
    workspace(1)
    frames_b = sample("caseB", 7)
    time.sleep(.5)
    settled_b = shot("caseB-settled.png")

    def peak(frames, key):
        return max((f[key] for f in frames), default=0)

    # A rigid slide never makes a neighbor more visible than its resting peek.
    # Allow a small tolerance for rasterization; the bug more than doubled it.
    tol = 1.1
    checks = [
        ("caseA observed animation", len(frames_a) > 0, len(frames_a)),
        ("caseB observed animation", len(frames_b) > 0, len(frames_b)),
        ("caseA blue never exceeds rest", peak(frames_a, "blue") <= rest["blue"] * tol,
         (peak(frames_a, "blue"), rest["blue"])),
        ("caseB red never exceeds rest", peak(frames_b, "red") <= rest_b["red"] * tol,
         (peak(frames_b, "red"), rest_b["red"])),
        ("caseA settled empty", sum(settled_a.values()) == 0, settled_a),
        ("caseB settled empty", sum(settled_b.values()) == 0, settled_b),
    ]
    for label, ok, detail in checks:
        print(f"{'ok' if ok else 'FAIL'}: {label} {detail}")
        if not ok:
            failures.append(label)
    if failures:
        raise AssertionError(f"issue #135 regression: {failures}; artifacts: {work}")
    print("PASS: empty-workspace scrolling swap keeps hidden columns hidden")
finally:
    for p in reversed(processes):
        if p.poll() is None:
            p.terminate()
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
    for log in logs:
        log.close()
    if not failures:
        import shutil
        shutil.rmtree(work, ignore_errors=True)
    else:
        print(f"Artifacts: {work}")