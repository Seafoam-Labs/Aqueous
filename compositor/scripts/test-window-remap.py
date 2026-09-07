#!/usr/bin/env python3
"""Headless two-output hide/show regression, including actual rendered pixels.

Models a tray application's persistent window; --electron adds a real
BrowserWindow close-to-tray fixture. Does not launch Discord itself.
Exercises native Wayland and XWayland, with fresh-process controls and repeated
cross-output remaps. Keeps logs, scene dumps, screenshots, and results in /tmp.
Use a -Dxwayland -Dvulkan-effects=false build for --renderer pixman (default),
or an effects build with --renderer vulkan and an available Vulkan device.
Requires cc, pkg-config, wayland-scanner, Xwayland, grim, and Python Pillow.
"""
import argparse
import json
import math
import os
from pathlib import Path
import shlex
import socket
import subprocess
import tempfile
import time

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
TARGET = "aqueous.remap-target"
COLOR = (224, 48, 112)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compositor", type=Path, default=ROOT / "zig-out/bin/aqueous")
    parser.add_argument("--ctl", type=Path, default=ROOT / "zig-out/bin/aqueousctl")
    parser.add_argument("--renderer", choices=["pixman", "vulkan"], default="pixman")
    parser.add_argument("--cycles", type=int, default=3)
    parser.add_argument("--electron", type=Path,
                        help="also exercise close-to-tray with this Electron executable (Wayland and X11)")
    parser.add_argument("--backend", action="append", choices=["wayland", "x11", "electron-wayland", "electron-x11"],
                        help="restrict to a backend; repeat to select several")
    parser.add_argument("--second-scale", type=float, default=1.0)
    parser.add_argument("--negative-control", action="store_true",
                        help="withhold the native Wayland remap buffer; the test MUST fail after fresh controls pass")
    parser.add_argument("--timing", choices=["settled", "rapid", "interrupt", "transfer", "same-size", "equal-size-transfer"], default="equal-size-transfer",
                        help="rapid hide/show, hide during a live output-transfer animation, or repeated live transfers")
    args = parser.parse_args()
    if args.cycles < 1:
        parser.error("--cycles must be positive")
    if any(b.startswith("electron-") for b in args.backend or []) and not args.electron:
        parser.error("Electron backends require --electron")
    if not math.isfinite(args.second_scale) or not 0.5 <= args.second_scale <= 3:
        parser.error("--second-scale must be between 0.5 and 3")
    work = Path(tempfile.mkdtemp(prefix="aqueous-window-remap-"))
    print(f"Artifacts: {work}", flush=True)
    (work / "run.json").write_text(json.dumps(vars(args), default=str, indent=2))
    env = dict(os.environ)
    processes, logs, results = [], [], []

    def run(command, **kwargs):
        result = subprocess.run([str(a) for a in command], env=env,
                                capture_output=True, text=True, timeout=10, **kwargs)
        if result.returncode:
            raise RuntimeError(f"{command}: {result.stderr or result.stdout}")
        return result.stdout

    def launch(command, name):
        log = (work / f"{name}.log").open("w")
        logs.append(log)
        process = subprocess.Popen([str(a) for a in command], env=env,
                                   stdin=subprocess.PIPE, stdout=log, stderr=log)
        processes.append(process)
        return process

    def wait_for(predicate, message):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            for process in processes:
                if process.poll() is not None:
                    raise AssertionError(f"process exited ({process.returncode}): {process.args}")
            value = predicate()
            if value:
                return value
            time.sleep(0.05)
        raise AssertionError(message)

    def stop(process):
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
        process.stdin.close()
        processes.remove(process)

    def command(process, value):
        process.stdin.write(value.encode())
        process.stdin.flush()

    protocols = Path(run(["pkg-config", "--variable=pkgdatadir", "wayland-protocols"]).strip())
    for name, xml in [
        ("xdg-shell", protocols / "stable/xdg-shell/xdg-shell.xml"),
        ("wlr-virtual-pointer-unstable-v1", ROOT / "protocol/upstream/wlr-virtual-pointer-unstable-v1.xml"),
    ]:
        run(["wayland-scanner", "client-header", xml, work / f"{name}-client-protocol.h"])
        run(["wayland-scanner", "private-code", xml, work / f"{name}-protocol.c"])
    cc = ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", f"-I{work}"]
    source = ROOT / "scripts/fixtures/window-remap.c"
    for backend in ("wayland", "x11"):
        flags = ["-DX11"] if backend == "x11" else [work / "xdg-shell-protocol.c"]
        libs = "x11" if backend == "x11" else "wayland-client"
        run([*cc, source, *flags, "-o", work / backend,
             *shlex.split(run(["pkg-config", "--cflags", "--libs", libs]))])
    run([*cc, ROOT / "scripts/fixtures/virtual-pointer-position.c",
         work / "wlr-virtual-pointer-unstable-v1-protocol.c", "-o", work / "pointer",
         *shlex.split(run(["pkg-config", "--cflags", "--libs", "wayland-client"]))])

    try:
        backends = ["wayland", "x11"]
        if args.electron:
            backends += ["electron-wayland", "electron-x11"]
        if args.backend:
            backends = args.backend
        if args.negative_control:
            backends = ["wayland"]
        for backend in backends:
            runtime = work / f"{backend}-runtime"
            runtime.mkdir(mode=0o700)
            for directory in ("config", "home", "cache", "state"):
                (runtime / directory).mkdir()
            for key in ("DISPLAY", "WAYLAND_DISPLAY", "LD_PRELOAD", "WAYLAND_SOCKET", "ELECTRON_RUN_AS_NODE"):
                env.pop(key, None)
            env.update(XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(runtime / "config"),
                       HOME=str(runtime / "home"), XDG_CACHE_HOME=str(runtime / "cache"),
                       XDG_STATE_HOME=str(runtime / "state"), WLR_BACKENDS="headless",
                       WLR_HEADLESS_OUTPUTS="2", WLR_RENDERER=args.renderer,
                       AQUEOUS_DEBUG_WINDOW_STATE="1")
            for key, filename in [("AQUEOUS_CONFIG", "wm.toml"), ("AQUEOUS_RULES", "rules.toml"),
                                  ("AQUEOUS_LAYOUT", "layout.toml"), ("AQUEOUS_INPUT", "input.toml"),
                                  ("AQUEOUS_OUTPUTS", "outputs.toml")]:
                env[key] = str(runtime / filename)
                (runtime / filename).write_text("")
            (runtime / "wm.toml").write_text('''[layout]
default = "tile"
gaps_outer = 0
gaps_inner = 0
border_width = 2
[opacity]
enabled = false
[blur]
enabled = false
[input]
focus_follows_mouse = true
''')
            # The compositor supplies its own XWayland DISPLAY to startup commands.
            startup = runtime / "startup.sh"
            startup.write_text('printf "%s" "$DISPLAY" > ' + shlex.quote(str(runtime / "display")) + "\n")
            launch([args.compositor.resolve(), "-policy", "internal", "-log-level", "debug",
                    "-c", "sh " + shlex.quote(str(startup))], f"{backend}-compositor")
            wayland = wait_for(lambda: next((p for p in runtime.glob("wayland-*") if p.is_socket()), None),
                               "Wayland socket did not appear")
            env["WAYLAND_DISPLAY"] = wayland.name
            wait_for(lambda: (runtime / "display").exists(), "startup command did not run")
            env["DISPLAY"] = (runtime / "display").read_text()
            assert env["DISPLAY"], "test requires an XWayland-enabled compositor"

            def output_request(request):
                with socket.socket(socket.AF_UNIX) as connection:
                    connection.settimeout(3)
                    connection.connect(str(runtime / "aqueous/outputd.sock"))
                    connection.sendall(json.dumps(request).encode() + b"\n")
                    with connection.makefile("r") as response:
                        return json.loads(response.readline())

            wait_for(lambda: (runtime / "aqueous/outputd.sock").exists(), "output service did not start")
            outputs = output_request({"op": "list"})["outputs"]
            assert len(outputs) == 2, outputs
            names = [output["name"] for output in outputs]
            response = output_request({"op": "set", "changes": [
                {"name": names[0], "scale": 1, "position": [0, 0]},
                {"name": names[1], "scale": args.second_scale, "position": [1280, 0]},
            ]})
            assert response["ok"], response

            # Keep one pointer alive throughout the session. Creating/removing
            # a virtual input device per move schedules unrelated manage work
            # and can accidentally re-enable a window whose map missed a render.
            pointer_fifo = runtime / "pointer.commands"
            os.mkfifo(pointer_fifo)
            launch([work / "pointer", pointer_fifo,
                    1280 + round(1280 / args.second_scale), max(720, round(720 / args.second_scale))],
                   f"{backend}-pointer")
            wait_for(lambda: "READY" in (work / f"{backend}-pointer.log").read_text(), "persistent pointer not ready")

            def pointer(index):
                fd = os.open(pointer_fifo, os.O_WRONLY | os.O_NONBLOCK)
                try:
                    os.write(fd, f"{100 + 1280 * index} 100\n".encode())
                finally:
                    os.close(fd)
                wait_for(lambda: abs(output_request({"op": "cursor_state"})["x"] - (100 + 1280 * index)) < 1,
                         "pointer did not select the destination output")

            def windows():
                # Enumeration and per-window snapshots are separate protocol
                # requests. A window can disappear between them during hide.
                for attempt in range(6):
                    try:
                        return json.loads(run([args.ctl.resolve(), "windows", "--json"]))
                    except RuntimeError as error:
                        transient = any(message in str(error) for message in (
                            "foreign toplevel is not owned by Aqueous", "foreign toplevel is no longer mapped"))
                        if not transient or attempt == 5:
                            raise
                        time.sleep(0.01)

            def target_window():
                return next((w for w in windows() if w.get("app_id") == TARGET or
                             w.get("class") == TARGET or w.get("title") == TARGET), None)

            def launch_target(label):
                if backend.startswith("electron-"):
                    prefix = ["env", "WAYLAND_DEBUG=client"] if backend == "electron-wayland" else []
                    return launch([*prefix, args.electron.resolve(),
                                   f"--ozone-platform={backend.removeprefix('electron-')}",
                                   f"--user-data-dir={runtime / label}", f"--class={TARGET}",
                                   "--no-first-run", "--disable-dev-shm-usage",
                                   ROOT / "scripts/fixtures/electron-window-remap.cjs"], f"{backend}-{label}")
                prefix = ["env", "AQUEOUS_REMAP_WITHHOLD_BUFFER=1"] if args.negative_control else []
                return launch([*prefix, work / backend, TARGET, "e03070"], f"{backend}-{label}")

            def capture(label):
                observations = []
                state = windows()
                (work / f"{backend}-{label}-windows.json").write_text(json.dumps(state, indent=2))
                (work / f"{backend}-{label}-scene.txt").write_text(run([args.ctl.resolve(), "scene"]))
                for index, name in enumerate(names):
                    path = work / f"{backend}-{label}-output{index + 1}.png"
                    run(["grim", "-s", "1", "-o", name, path])
                    with Image.open(path) as image:
                        image = image.convert("RGB")
                        # Allow small rounding differences in the Vulkan path.
                        count = sum(n for n, rgb in image.getcolors(image.width * image.height)
                                    if max(abs(a - b) for a, b in zip(rgb, COLOR)) <= 3)
                    observations.append(count)
                return observations

            def scene_state(label):
                # Reading the scene does not request a render or screencopy.
                scene = run([args.ctl.resolve(), "scene"])
                (work / f"{backend}-{label}-passive-scene.txt").write_text(scene)
                return scene

            def move_target(destination):
                window = wait_for(target_window, "cannot move an unpublished window")
                response = json.loads(run([args.ctl.resolve(), "window", "move", "--id", window["id"],
                                           "--output", names[destination], "--json"]))
                assert response.get("ok", response.get("status") == "ok"), response

            def check(label, destination):
                wait_for(target_window, f"{label}: no mapped/published target; inspect configure/commit log")
                time.sleep(0.5)  # Allow normal movement animation to settle.
                counts = capture(label)
                window = target_window()
                assert window, f"{label}: target disappeared"
                geometry = window["geometry"]
                expected = geometry["width"] * geometry["height"]
                if label in ("fresh-process-control", "initial"):
                    # Electron's initial GPU/browser startup can outlast the
                    # first map. Establish actual content before timing remaps.
                    # Capture polling is restricted to setup, never recovery.
                    def ready_pixels():
                        observed = capture(label)
                        return observed if observed[destination] >= expected * 0.85 else None
                    if counts[destination] < expected * 0.85:
                        counts = wait_for(ready_pixels, f"{label}: initial client content did not render")
                assert geometry["width"] > 32 and geometry["height"] > 32, window
                output_width = 1280 if destination == 0 else round(1280 / args.second_scale)
                assert 1280 * destination <= geometry["x"] < 1280 * destination + output_width, window
                assert counts[destination] >= expected * 0.85, (
                    f"{label}: mapped/published but not visibly rendered in its tile; "
                    f"pixels={counts}, geometry={geometry}. Inspect scene/opacity/clip state.")
                path = work / f"{backend}-{label}-output{destination + 1}.png"
                with Image.open(path) as image:
                    x, y = geometry["x"] - 1280 * destination, geometry["y"]
                    tile = image.convert("RGB").crop((x, y, x + geometry["width"], y + geometry["height"]))
                    tile_pixels = sum(n for n, rgb in tile.getcolors(tile.width * tile.height)
                                      if max(abs(a - b) for a, b in zip(rgb, COLOR)) <= 3)
                assert tile_pixels >= expected * 0.85, f"{label}: pixels are outside the assigned tile"
                assert counts[1 - destination] == 0, f"{label}: stale pixels on the previous output: {counts}"
                results.append({"backend": backend, "phase": label, "pixels": counts, "window": window})
                print(f"PASS {backend}: {label} (output {destination + 1}, {counts[destination]} pixels)", flush=True)

            # Two companion windows on output 2 make admission visibly change
            # the stack, matching the terminal/browser arrangement in the report.
            pointer(1)
            for number, color in enumerate(("208040", "3040c0")):
                launch([work / "wayland", f"aqueous.companion{number}", color], f"{backend}-companion{number}")
                wait_for(lambda: len(windows()) == number + 1, "companion did not map")
            if args.timing == "equal-size-transfer":
                # Equal layout slots on both outputs isolate output changes
                # from resize-driven rendering, which otherwise masks map bugs.
                pointer(0)
                for number, color in enumerate(("208040", "3040c0")):
                    launch([work / "wayland", f"aqueous.source-companion{number}", color],
                           f"{backend}-source-companion{number}")
                    wait_for(lambda: len(windows()) == number + 3, "source companion did not map")
                pointer(1)
            # Establish the destination's fresh-process control before any
            # remap can fail, so a failure still has a valid comparison.
            client = launch_target("fresh-target")
            check("fresh-process-control", 1)
            command(client, "q")
            client.wait(timeout=3)
            client.stdin.close()
            processes.remove(client)
            wait_for(lambda: target_window() is None, "fresh process did not release its window")
            pointer(0)
            client = launch_target("target")
            check("initial", 0)
            for cycle in range(args.cycles):
                for destination in ((0,) if args.timing == "same-size" else (1, 0)):
                    label = f"cycle{cycle + 1}-to{destination + 1}"
                    if args.timing in ("transfer", "interrupt"):
                        move_target(destination)
                        if args.timing == "transfer":
                            scene_state(label + "-moving")
                            continue
                        wait_for(
                            lambda: next((line for line in scene_state(label + "-moving").splitlines()
                                          if f"window: {TARGET}" in line and "anim=true" in line), None),
                            "test setup: cross-output move did not start an animation")
                        print(f"OBSERVED {backend}: active output-transfer animation", flush=True)
                    command(client, "h")
                    if args.timing != "rapid":
                        wait_for(lambda: target_window() is None, f"{label}: hide did not unmap the window")
                    if args.timing == "settled":
                        time.sleep(0.15)
                        assert capture(label + "-hidden") == [0, 0], "hidden window retained visible pixels"
                    if args.timing == "interrupt":
                        time.sleep(0.65)
                        scene_state(label + "-hidden")
                    pointer(destination)
                    command(client, "s")
                    if args.timing != "settled":
                        if args.timing == "equal-size-transfer":
                            time.sleep(0.5)
                            passive = scene_state(label + "-before-capture")
                            try:
                                target_line = next((line for line in passive.splitlines()
                                                    if f"window: {TARGET}" in line), "")
                                assert target_line and "[tree] disabled" not in target_line, (
                                    f"{label}: reopened target scene is absent/disabled before screenshot: {target_line.strip()}")
                            except Exception:
                                capture(label + "-failure")
                                raise
                        scene_state(label + "-reopened")
                        continue
                    try:
                        check(label, destination)
                    except Exception:
                        capture(label + "-failure")
                        raise
            if args.timing != "settled":
                # Allow recovery without captures or pointer activity, then
                # record passive state BEFORE the first post-sequence capture.
                time.sleep(1)
                passive = scene_state("final-before-capture")
                try:
                    target_line = next((line for line in passive.splitlines() if f"window: {TARGET}" in line), "")
                    assert target_line, "target scene node missing before screenshot"
                    assert "[tree] disabled" not in target_line, (
                        f"target scene node is disabled before any post-sequence screenshot: {target_line.strip()}")
                    check("final-after-" + args.timing, 0)
                except Exception:
                    capture("final-failure")
                    raise
            for process in list(reversed(processes)):
                stop(process)
    except Exception as error:
        results.append({"status": "failed", "backend": backend, "error": str(error)})
        raise
    finally:
        for process in list(reversed(processes)):
            stop(process)
        for log in logs:
            log.close()
        (work / "results.json").write_text(json.dumps(results, indent=2))
    print("PASS: all selected backends remap visibly across both outputs", flush=True)


if __name__ == "__main__":
    main()
