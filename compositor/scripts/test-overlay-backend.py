#!/usr/bin/env python3
"""Exercise patched DRM decision/property code with mocked KMS, without a GPU.

Pass the patched wlroots source directory and its installed prefix. Extract
complete internal functions so this tests the production code without exporting
private wlroots symbols or linking a real DRM backend into the test process.
"""
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile


def function(source, name):
    match = re.search(r"^(?:static )?(?:bool|int|uint64_t|void) " + name + r"\(", source, re.M)
    if match is None:
        raise RuntimeError(f"missing production function: {name}")
    start = source.index("{", match.start())
    depth = 1
    end = start + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[match.start():end] + "\n"


source, prefix = map(Path, sys.argv[1:])
functions = ""
for file, names in {
    "backend/drm/drm.c": ["can_fallback_from_liftoff"],
    "backend/drm/atomic.c": ["max_bpc_for_format", "drm_atomic_pick_max_bpc"],
    "backend/drm/libliftoff.c": [
        "finish", "add_prop", "set_plane_props", "set_layer_in_fence", "disable_plane",
        "to_fp16", "set_layer_props", "add_connector",
    ],
}.items():
    contents = (source / file).read_text()
    functions += "\n".join(function(contents, name) for name in names)

env = dict(os.environ, PKG_CONFIG_PATH=str(prefix / "lib/pkgconfig"))
flags = shlex.split(subprocess.check_output(
    ["pkg-config", "--cflags", "--libs", "wlroots-0.20", "libliftoff", "wayland-server"],
    env=env, text=True))
with tempfile.TemporaryDirectory(prefix="aqueous-overlay-backend-") as tmp:
    tmp = Path(tmp)
    (tmp / "overlay-functions.h").write_text(functions)
    subprocess.run([
        "cc", "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-DWLR_USE_UNSTABLE",
        "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
        "-I" + str(source / "include"), "-I" + str(tmp),
        str(Path(__file__).parent / "fixtures/overlay-backend.c"),
        *flags, "-lm", "-o", str(tmp / "test"),
    ], check=True)
    subprocess.run([str(tmp / "test")], check=True,
                   env=dict(env, LD_LIBRARY_PATH=str(prefix / "lib")))
print("PASS: startup fallback policy, HDR/SDR connector state, fence transitions")
