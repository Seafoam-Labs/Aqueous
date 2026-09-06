#!/usr/bin/env python3
"""Compare static color patches across real transaction and animation snapshots.

Uses an isolated nested Vulkan compositor (SDR output). This does not establish
hardware HDR correctness. Requires Pillow, grim, wlrctl, and Wayland development
tools. Run against an unpatched compositor with --compositor to verify failure.
Run graphical tests serially: obscured nested windows may stop receiving frames.
"""
import argparse
from collections import Counter
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
parser.add_argument("--opacity", type=float, default=1.0)
parser.add_argument("--blur", action="store_true")
args = parser.parse_args()
assert 0 < args.opacity <= 1
work = Path(tempfile.mkdtemp(prefix="aqueous-snapshot-colors-"))
runtime = work / "runtime"
runtime.mkdir(mode=0o700)
(runtime / "host").symlink_to(Path(os.environ["XDG_RUNTIME_DIR"]) / os.environ["WAYLAND_DISPLAY"])
env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / "config"),
           XDG_CACHE_HOME=str(work / "cache"), XDG_STATE_HOME=str(work / "state"),
           WLR_BACKENDS="wayland", WLR_WL_OUTPUTS="1", WAYLAND_DISPLAY="host")
env.pop("LD_PRELOAD", None)
env.pop("DISPLAY", None)
for key, filename in [("AQUEOUS_CONFIG", "wm.toml"), ("AQUEOUS_RULES", "rules.toml"),
                      ("AQUEOUS_LAYOUT", "layout.toml"), ("AQUEOUS_INPUT", "input.toml"),
                      ("AQUEOUS_OUTPUTS", "outputs.toml")]:
    env[key] = str(work / filename)
(work / "wm.toml").write_text(f'''[layout]
default = "floating"
gaps_outer = 0
gaps_inner = 0
border_width = 0
[opacity]
enabled = true
value = {args.opacity}
focus_sensitive = false
[blur]
enabled = {str(args.blur).lower()}
radius = 10
passes = 3
[input]
focus_follows_mouse = false
[workspace_transition]
enabled = true
rate = 3.0
[keybinds]
focus_workspace_1 = "Super+1"
focus_workspace_2 = "Super+2"
''')
(work / "rules.toml").write_text('''[[window]]
app_id = "aqueous.snapshot-color"
floating = true
width = 400
height = 320
x = 200
y = 150
''')

def run(command, **kwargs):
    result = subprocess.run([str(a) for a in command], env=env,
                            capture_output=True, text=True, timeout=15, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{command}: {result.stderr}")
    return result.stdout

protocols = Path(run(["pkg-config", "--variable=pkgdatadir", "wayland-protocols"]).strip())
generated = []
for name, protocol in [("xdg-shell", "stable/xdg-shell/xdg-shell.xml"),
                       ("color-management-v1", "staging/color-management/color-management-v1.xml")]:
    run(["wayland-scanner", "client-header", protocols / protocol, work / f"{name}-client-protocol.h"])
    source = work / f"{name}-protocol.c"
    run(["wayland-scanner", "private-code", protocols / protocol, source])
    generated.append(source)
run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", f"-I{work}",
     ROOT / "scripts/fixtures/snapshot-color-client.c", *generated, "-o", work / "client",
     *shlex.split(run(["pkg-config", "--cflags", "--libs", "wayland-client"]))])

processes = []
logs = []
def launch(command, name):
    log = (work / f"{name}.log").open("w")
    logs.append(log)
    process = subprocess.Popen([str(a) for a in command], env=env, stdout=log, stderr=log)
    processes.append(process)
    return process

def wait_for(predicate, message):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        assert all(p.poll() is None for p in processes), f"process exited: {work}"
        value = predicate()
        if value:
            return value
        time.sleep(0.025)
    raise AssertionError(message)

ctl = ROOT / "zig-out/bin/aqueousctl"
def windows():
    return json.loads(run([ctl, "windows", "--json"]))

def capture(name):
    path = work / f"{name}.png"
    run(["grim", path])
    with Image.open(path) as image:
        rgb_image = image.convert("RGB")
        pixels = list(rgb_image.get_flattened_data() if hasattr(rgb_image, "get_flattened_data") else rgb_image.getdata())
        # Solid patch interiors dwarf borders and antialiasing pixels. Ignore
        # empty black output and require enough visible area to compare.
        counts = Counter(pixels)
        palette = [rgb for rgb, n in counts.items() if n >= 4096 and max(rgb) > 20]
        xs = [i % image.width for i, rgb in enumerate(pixels) if rgb in palette]
        return palette, min(xs) if xs else None

def distance(a, b):
    return max(abs(x - y) for x, y in zip(a, b))

try:
    launch([args.compositor.resolve(), "-no-xwayland", "-policy", "internal",
            "-log-level", "debug", "-c", "true"], "compositor")
    socket = wait_for(lambda: next(runtime.glob("wayland-*"), None), "no Wayland socket")
    env["WAYLAND_DISPLAY"] = socket.name
    launch([work / "client"], "client")
    window = wait_for(lambda: next((w for w in windows() if w["app_id"] == "aqueous.snapshot-color"), None),
                      "color-managed client did not map")
    time.sleep(0.5)
    reference, _ = capture("reference")
    assert len(reference) == 4, f"expected four reference patches, got {reference}"
    failures = []
    frame_count = 0
    saved_frames = 0
    positions = set()

    def sample(phase, seconds):
        global frame_count, saved_frames
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if phase == "resize":
                scene = run([ctl, "scene"])
                (work / f"scene-{frame_count:03}.txt").write_text(scene)
                if any("saved surfaces [tree]" in line and "disabled" not in line for line in scene.splitlines()):
                    saved_frames += 1
            palette, x = capture(f"{phase}-{frame_count:03}")
            frame_count += 1
            if x is not None and phase.startswith("slide"):
                positions.add(x)
            for color in palette:
                # Two 8-bit levels allow rounding/dithering, not a changed TF.
                if min(distance(color, expected) for expected in reference) > 2:
                    failures.append((phase, color))

    run(["wlrctl", "keyboard", "type", "2", "modifiers", "SUPER"])
    sample("slide-out", 2.6)
    run(["wlrctl", "keyboard", "type", "1", "modifiers", "SUPER"])
    sample("slide-in", 2.6)
    assert len(positions) >= 3, f"animation was not observed: {positions}"
    # A changing configure keeps the old transaction buffers visible while the
    # fixture briefly delays its response. Collect frames concurrently with IPC.
    request = launch([ctl, "window", "state", "--id", window["id"], "--maximized", "true", "--json"], "maximize")
    time.sleep(0.01)
    sample("resize", 0.7)
    assert request.wait(timeout=5) == 0
    assert saved_frames > 0, "no transaction snapshot was observed during resize"
    settled, _ = capture("settled")
    assert len(settled) == 4 and all(min(distance(c, r) for r in reference) <= 2 for c in settled)
    (work / "results.json").write_text(json.dumps(dict(reference=reference, frames=frame_count,
        animation_positions=sorted(positions), saved_frames=saved_frames,
        failures=failures, opacity=args.opacity, blur=args.blur), indent=2))
    assert not failures, f"snapshot colors differ from live reference: {failures[:8]}"
    print(f"PASS: {frame_count} frames, {len(positions)} animation positions; artifacts: {work}")
finally:
    for process in reversed(processes):
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    for log in logs:
        log.close()
    print(f"Snapshot color test artifacts: {work}")
