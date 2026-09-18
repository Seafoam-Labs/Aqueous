#!/usr/bin/env python3
"""Run real NVIDIA XWayland swapchain calls, isolated per case with a timeout.

Requires cc, pkg-config, Vulkan/XCB development files and an active XWayland.
Creates briefly visible diagnostic windows; does not change session settings.
"""
import argparse
import itertools
import os
from pathlib import Path
import shlex
import signal
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New directory for per-case logs")
    parser.add_argument("--validate", action="store_true", help="Require installed Khronos validation layer")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    flags = shlex.split(subprocess.check_output(["pkg-config", "--cflags", "--libs", "vulkan", "xcb"], text=True))
    source = Path(__file__).parent / "fixtures/xwayland-vulkan-probe.c"
    with tempfile.TemporaryDirectory(prefix="aqueous-wsi-probe-") as tmp:
        binary = Path(tmp) / "probe"
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-g", str(source), "-o", str(binary), *flags], check=True)
        cases = [(f"{w}x{h}-{mode}-{profile}", w, h, mode, profile, "inherited")
                 for (w, h), mode, profile in itertools.product(
                     [(800, 600), (3840, 1600)], ["fifo", "immediate"], ["basic", "mutable", "maintenance"])]
        cases += [(name, 800, 600, "fifo", "basic", name)
                  for name in ["without-vulkan-pin", "without-device-select-layer", "without-glx-pin"]]
        rows = []
        for name, width, height, mode, profile, environment in cases:
            env = os.environ.copy()
            if args.validate:
                env["VK_INSTANCE_LAYERS"] = "VK_LAYER_KHRONOS_validation"
            if environment == "without-vulkan-pin":
                env.pop("MESA_VK_DEVICE_SELECT", None)
            elif environment == "without-device-select-layer":
                env["NODEVICE_SELECT"] = "1"
            elif environment == "without-glx-pin":
                env.pop("__GLX_VENDOR_LIBRARY_NAME", None)
            log = args.output / f"{name}.log"
            with log.open("w") as stream:
                process = subprocess.Popen([str(binary), str(width), str(height), mode, profile],
                                           env=env, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    rc = process.wait(timeout=15)
                    status = "PASS" if rc == 0 else "SKIP" if rc == 77 else f"FAIL ({rc})"
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                    status = "TIMEOUT"
            contents = log.read_text(errors="replace")
            if "Validation Error" in contents or "VUID-" in contents:
                status = "VALIDATION ERROR"
            calls = [line for line in contents.splitlines() if line.startswith("CALL ")]
            last_call = calls[-1] if calls else "No Vulkan call reached"
            row = f"{status}\t{name}\t{last_call}"
            rows.append(row)
            print(row, flush=True)
        summary = "\n".join(rows) + "\n"
        (args.output / "summary.txt").write_text(summary)
        return int(any(not row.startswith(("PASS\t", "SKIP\t")) for row in rows))


if __name__ == "__main__":
    raise SystemExit(main())
