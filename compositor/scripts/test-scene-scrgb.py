#!/usr/bin/env python3
"""Exercise production scene luminance and real color-management commits, GPU-free."""
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

source, prefix = (Path(p).resolve() for p in sys.argv[1:])
env = dict(os.environ)
for key, directory in (("PKG_CONFIG_PATH", "lib/pkgconfig"), ("LD_LIBRARY_PATH", "lib")):
    env[key] = str(prefix / directory) + (":" + env[key] if env.get(key) else "")
flags = shlex.split(subprocess.check_output(
    ["pkg-config", "--cflags", "--libs", "wlroots-0.20", "wayland-client", "wayland-server"],
    env=env, text=True))
protocols = Path(subprocess.check_output(
    ["pkg-config", "--variable=pkgdatadir", "wayland-protocols"], env=env, text=True).strip())


def function(contents, name):
    match = re.search(r"^(?:static )?\w+ [^;\n]*\b" + name + r"\(", contents, re.M)
    if match is None:
        raise RuntimeError(f"missing production function: {name}")
    start = contents.index("{", match.start())
    depth, end = 1, start + 1
    while depth:
        depth += (contents[end] == "{") - (contents[end] == "}")
        end += 1
    return contents[match.start():end] + "\n"


with tempfile.TemporaryDirectory(prefix="aqueous-scene-scrgb-") as directory:
    tmp = Path(directory)
    scene = (source / "types/scene/wlr_scene.c").read_text()
    # Compile the exact private helpers; no public test API or copied formula.
    color = (source / "render/color.c").read_text()
    (tmp / "scene-luminance.h").write_text(
        function(color, "wlr_color_transfer_function_get_default_luminance") +
        "\n".join(function(scene, name) for name in (
            "get_luminance_multiplier", "scene_buffer_luminance")))
    generated = []
    for name in ("color-management", "single-pixel-buffer"):
        protocol = f"{name}-v1"
        xml = protocols / "staging" / name / f"{protocol}.xml"
        for mode, filename in (("client-header", f"{protocol}-client-protocol.h"),
                               ("private-code", f"{protocol}-protocol.c")):
            subprocess.run(["wayland-scanner", mode, str(xml), str(tmp / filename)], check=True)
        generated.append(str(tmp / f"{protocol}-protocol.c"))
    subprocess.run([
        *shlex.split(os.environ.get("CC", "cc")), "-std=c11", "-DWLR_USE_UNSTABLE",
        "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter", "-O2",
        *shlex.split(os.environ.get("CFLAGS", "")), "-UNDEBUG", "-I" + str(tmp),
        str(Path(__file__).parent / "fixtures/scene-scrgb.c"), *generated,
        *flags, "-lm", "-o", str(tmp / "test"),
    ], check=True, env=env)
    subprocess.run([str(tmp / "test")], check=True, env=env, timeout=30)
