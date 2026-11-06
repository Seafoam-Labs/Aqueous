#!/usr/bin/env python3
"""Observe callback-paced root/independent-child pixels during real slide frames.

Requires grim, wlrctl, Pillow and Wayland development tools.
Runs a private headless Vulkan compositor. --compositor accepts an older
binary for a negative control. Artifacts are retained under /tmp/opencode.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--compositor", type=Path, default=ROOT / "zig-out/bin/aqueous")
parser.add_argument("--ctl", type=Path, default=ROOT / "zig-out/bin/aqueousctl")
parser.add_argument("--child-only", action="store_true")
parser.add_argument("--scrolling", action="store_true")
parser.add_argument("--renderer", choices=("vulkan", "pixman"), default="vulkan")
args = parser.parse_args()
work = Path(tempfile.mkdtemp(prefix="live-slide-", dir="/tmp/opencode"))
runtime = work / "runtime"
runtime.mkdir(mode=0o700)
env = {k: v for k, v in os.environ.items() if not k.startswith(("AQUEOUS_", "WLR_", "DMS_"))
       and k not in ("WAYLAND_DISPLAY", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "LD_PRELOAD")}
env.update(XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / "config"),
           XDG_CACHE_HOME=str(work / "cache"), XDG_STATE_HOME=str(work / "state"),
           WLR_BACKENDS="headless", WLR_HEADLESS_OUTPUTS="1", WLR_RENDERER=args.renderer,
           AQUEOUS_DEBUG_WINDOW_STATE="1")
env.pop("LD_PRELOAD", None)
env.pop("DISPLAY", None)
for name in ("config", "rules", "layout", "input", "outputs"):
    env["AQUEOUS_" + name.upper()] = str(work / (name + ".toml"))
(work / "config.toml").write_text(f'''[layout]
default = "{'scrolling' if args.scrolling else 'floating'}"
border_width = 0
[layout.options.scrolling]
column_fraction = 0.75
center_focused = true
follow_new_windows = true
[input]
focus_follows_mouse = false
[workspace_transition]
enabled = true
rate = 1.5
[keybinds]
focus_workspace_1 = "Super+1"
focus_workspace_2 = "Super+2"
''')
app_id = "aqueous.live-slide-" + ("child" if args.child_only else "root")
(work / "rules.toml").write_text(f'''[[window]]
app_id = "{app_id}"
floating = {str(not args.scrolling).lower()}
width = 400
height = 320
x = 400
y = 150
''')

def run(command):
    return subprocess.check_output([str(a) for a in command], env=env, text=True,
                                   stderr=subprocess.PIPE, timeout=15)

protocols = Path(run(["pkg-config", "--variable=pkgdatadir", "wayland-protocols"]).strip())
xml = protocols / "stable/xdg-shell/xdg-shell.xml"
run(["wayland-scanner", "client-header", xml, work / "xdg-shell-client-protocol.h"])
run(["wayland-scanner", "private-code", xml, work / "xdg-shell-protocol.c"])
run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", f"-I{work}",
     ROOT / "scripts/fixtures/live-slide-client.c", work / "xdg-shell-protocol.c", "-o", work / "client",
     *shlex.split(run(["pkg-config", "--cflags", "--libs", "wayland-client"]))])
processes, logs = [], []

def launch(command, name):
    log = (work / (name + ".log")).open("w")
    logs.append(log)
    p = subprocess.Popen([str(a) for a in command], env=env, stdout=log, stderr=log)
    processes.append(p)
    return p

def wait(predicate, message):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        assert all(p.poll() is None for p in processes), f"process exited: {work}"
        value = predicate()
        if value:
            return value
        time.sleep(.025)
    raise AssertionError(message)

def workspace(n):
    run(["wlrctl", "keyboard", "type", str(n), "modifiers", "SUPER"])

results = {}
def moving(scene):
    return any("window: Live slide counter" in line and "anim=true" in line for line in scene.splitlines())

def sample(phase, seconds):
    colors, positions = set(), set()
    deadline = time.monotonic() + seconds
    frames = 0
    while time.monotonic() < deadline:
        scene = run([args.ctl, "scene"])
        (work / f"{phase}-scene.txt").write_text(scene)
        if not moving(scene):
            time.sleep(.01)
            continue
        path = work / f"{phase}-{frames:03}.png"
        run(["grim", "-l", "0", path])
        if not moving(run([args.ctl, "scene"])):
            continue
        with Image.open(path) as image:
            image = image.convert("RGB")
            counts = image.getcolors(image.width * image.height)
            # Exclude background, borders, antialiasing and the static parent.
            candidates = [(n, rgb) for n, rgb in counts
                          if n > 1024 and 60 < rgb[1] < 105 and 140 < rgb[2] < 185]
            if candidates:
                _, color = max(candidates)
                colors.add(color)
                r, g, b = ImageChops.difference(image, Image.new("RGB", image.size, color)).split()
                mask = ImageChops.lighter(r, ImageChops.lighter(g, b)).point(lambda v: 0 if v else 255)
                bounds = mask.getbbox()
                positions.add((bounds[0], bounds[2] - 1))
        frames += 1
    results[phase] = dict(frames=frames, colors=sorted(colors), positions=sorted(positions))
    assert len(positions) >= 2, f"{phase}: did not observe moving content: {results[phase]}"
    assert len(colors) >= 2, f"{phase}: content frozen during animation: {results[phase]}"

try:
    launch([args.compositor.resolve(), "-no-xwayland", "-policy", "internal", "-log-level", "debug", "-c", "true"], "compositor")
    socket = wait(lambda: next((p for p in runtime.glob("wayland-*") if p.is_socket()), None), "no socket")
    env["WAYLAND_DISPLAY"] = socket.name
    client = launch([work / "client", *(["--child-only"] if args.child_only else [])], "client")
    window = wait(lambda: next((w for w in json.loads(run([args.ctl, "windows", "--json"])) if w["app_id"] == app_id), None), "client did not map")
    time.sleep(.5)
    if args.scrolling:
        run([args.ctl, "layout", "--output", "HEADLESS-1", "--set", "scrolling", "--json"])
        for i in range(2):
            launch([work / "client", "--static"], f"peer-{i}")
            wait(lambda: len(json.loads(run([args.ctl, "windows", "--json"]))) == i + 2, "peer did not map")
        peers = [w for w in json.loads(run([args.ctl, "windows", "--json"])) if w["id"] != window["id"]]
        run([args.ctl, "window", "activate", "--id", peers[-1]["id"], "--json"])
        time.sleep(1)
        (work / "scroll-before.txt").write_text(run([args.ctl, "scene"]))
        run([args.ctl, "window", "activate", "--id", window["id"], "--json"])
        (work / "scroll-after.txt").write_text(run([args.ctl, "scene"]))
        sample("scroll-in", .8)
    workspace(2)
    sample("outgoing", 1.3)
    time.sleep(4.5)
    workspace(1)
    sample("incoming", 1.6)
    # Interrupt an in-progress slide and verify the reversal remains live.
    workspace(2)
    time.sleep(.2)
    workspace(1)
    sample("reversal", 1.0)
    workspace(2)
    time.sleep(.1)
    client.terminate()
    client.wait(timeout=5)
    processes.remove(client)
    time.sleep(.5)
    assert all(p.poll() is None for p in processes), "compositor failed after unmap during slide"
    print(f"PASS {'child-only' if args.child_only else 'root'}: "
          f"{'scrolling, ' if args.scrolling else ''}live outgoing/incoming/reversed slides and unmap")
finally:
    (work / "results.json").write_text(json.dumps(results, indent=2))
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
    print(f"Artifacts: {work}")
