#!/usr/bin/env python3
"""GPU-free regression using the installed production wlroots scene implementation."""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

prefix = Path(sys.argv[1]).resolve()
env = dict(os.environ, PKG_CONFIG_PATH=str(prefix / "lib/pkgconfig"),
           LD_LIBRARY_PATH=str(prefix / "lib"))
flags = shlex.split(subprocess.check_output(
    ["pkg-config", "--cflags", "--libs", "wlroots-0.20", "wayland-server", "pixman-1"],
    env=env, text=True))
with tempfile.TemporaryDirectory(prefix="aqueous-scene-presentation-") as directory:
    binary = Path(directory) / "test"
    subprocess.run(["cc", "-std=c11", "-DWLR_USE_UNSTABLE", "-Wall", "-Wextra", "-Werror",
                    "-Wno-unused-parameter", "-g", "-UNDEBUG",
                    str(Path(__file__).parent / "fixtures/scene-presentation.c"),
                    *flags, "-lm", "-o", str(binary)], check=True, env=env)
    subprocess.run([str(binary)], check=True, env=env, timeout=30)
