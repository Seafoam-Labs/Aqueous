#!/usr/bin/env python3
"""Test the production color compiler and KMS lifetime paths without a GPU."""
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

source, prefix = map(lambda p: Path(p).resolve(), sys.argv[1:])
env = dict(os.environ, PKG_CONFIG_PATH=str(prefix / "lib/pkgconfig"),
           LD_LIBRARY_PATH=str(prefix / "lib"))
flags = shlex.split(subprocess.check_output(
    ["pkg-config", "--cflags", "--libs", "wlroots-0.20", "libdrm", "wayland-server"],
    env=env, text=True))


def function(contents, name):
    match = re.search(r"^static [^;\n]*\b" + name + r"\(", contents, re.M)
    if match is None:
        raise RuntimeError(f"missing production function: {name}")
    start = contents.index("{", match.start())
    depth, end = 1, start + 1
    while depth:
        depth += (contents[end] == "{") - (contents[end] == "}")
        end += 1
    return contents[match.start():end] + "\n"


with tempfile.TemporaryDirectory(prefix="aqueous-color-tests-") as directory:
    tmp = Path(directory)
    liftoff = (source / "backend/drm/libliftoff.c").read_text()
    (tmp / "liftoff-color.h").write_text("\n".join(
        function(liftoff, name) for name in (
            "assigned_plane", "add_color_pipelines", "reset_device_color_pipelines",
            "add_device_color_pipelines")))
    probe = tmp / "probe.c"
    probe.write_text("#include <xf86drm.h>\n#include <xf86drmMode.h>\n"
                     "int x = DRM_CLIENT_CAP_PLANE_COLOR_PIPELINE;\n"
                     "struct drm_color_ctm_3x4 matrix;\n"
                     "struct drm_color_lut32 lut;\n")
    result = subprocess.run(["cc", "-fsyntax-only", str(probe), *flags],
                            capture_output=True, env=env)
    if result.returncode:
        print("SKIP: system libdrm headers lack color-pipeline UAPI; backend remains disabled")
        sys.exit(0)
    (tmp / "config.h").write_text("#define HAVE_DRM_COLOR_PIPELINE 1\n")
    sanitizers = (["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
                  if os.environ.get("AQUEOUS_COLOR_SANITIZE") == "1" else [])
    subprocess.run([
        "cc", "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-DWLR_USE_UNSTABLE",
        "-DWLR_PRIVATE=", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
        "-I" + str(tmp), "-I" + str(source), "-I" + str(source / "include"),
        str(Path(__file__).parent / "fixtures/color-pipeline.c"),
        *flags, *sanitizers, "-lm", "-o", str(tmp / "test"),
    ], check=True, env=env)
    subprocess.run([str(tmp / "test")], check=True, env=env)
    (tmp / "config.h").write_text("#define HAVE_DRM_COLOR_PIPELINE 0\n")
    subprocess.run([
        "cc", "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-DWLR_USE_UNSTABLE",
        "-DWLR_PRIVATE=", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
        "-I" + str(tmp), "-I" + str(source / "include"), "-fsyntax-only",
        str(source / "backend/drm/color_pipeline.c"), *flags,
    ], check=True, env=env)
print("PASS: color pipeline topology, numeric mapping, buffer ownership, atomic cleanup")
