#!/usr/bin/env python3
"""Run synchronization fault tests against complete production wlroots functions.

Uses mocked Vulkan/DRM calls, real wlroots structures and real descriptor ownership.
No GPU required. Usage: test-vulkan-sync.py PATCHED_SOURCE INSTALLED_PREFIX
"""
import os
from pathlib import Path
import re
import resource
import shlex
import subprocess
import sys
import tempfile


def function(source, name):
    match = re.search(r"^[a-zA-Z][^\n;{}=]+\b" + name + r"\(", source, re.M)
    if not match:
        raise RuntimeError(f"missing production function: {name}")
    start = source.index("{", match.start())
    depth, end = 1, start + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[match.start():end] + "\n"


def main():
    source, prefix = map(Path, sys.argv[1:])
    selected = {
        "render/vulkan/renderer.c": [
            "vulkan_end_command_buffer", "vulkan_wait_command_buffer", "submit_stage",
            "release_command_buffer_resources", "vulkan_reset_command_buffer",
            "wait_last_submission", "signal_failed_pass", "vulkan_cancel_render_pass",
            "vulkan_recover_render_pass", "vulkan_fail_render_pass",
            "buffer_export_sync_file", "vulkan_sync_foreign_texture_acquire",
            "vulkan_sync_render_buffer_acquire", "buffer_import_sync_file",
            "vulkan_sync_render_pass_release",
        ],
        "render/vulkan/pass.c": [
            "get_render_pass", "get_color_transform", "bind_pipeline",
            "encode_proj_matrix", "encode_color_matrix", "convert_pixman_box_to_vk_rect",
            "vulkan_render_pass_destroy", "render_pass_wait_sync_file", "close_sync_files",
            "render_pass_wait_render_buffer", "render_pass_wait_textures", "render_pass_submit",
        ],
    }
    production = "\n".join(function((source / path).read_text(), name)
                           for path, names in selected.items() for name in names)
    env = dict(os.environ, PKG_CONFIG_PATH=str(prefix / "lib/pkgconfig"))
    flags = shlex.split(subprocess.check_output(
        ["pkg-config", "--cflags", "--libs", "wlroots-0.20", "vulkan", "libdrm", "wayland-server", "pixman-1"],
        env=env, text=True))
    # Generate no-op Vulkan command-recording entry points from official prototypes.
    # Submission, semaphore, wait and reset calls have stateful mocks in the fixture.
    vulkan_include = Path(subprocess.check_output(
        ["pkg-config", "--variable=includedir", "vulkan"], env=env, text=True).strip())
    vk = (vulkan_include / "vulkan/vulkan_core.h").read_text()
    stubs = ""
    for name in sorted(set(re.findall(r"\b(vkCmd\w+)\(", production))):
        declaration = re.search(r"VKAPI_ATTR void VKAPI_CALL " + name + r"\([\s\S]*?\);", vk)
        if not declaration:
            raise RuntimeError(f"missing Vulkan prototype: {name}")
        stubs += declaration.group()[:-1] + " {}\n"
    with tempfile.TemporaryDirectory(prefix="aqueous-vulkan-sync-") as tmp:
        tmp = Path(tmp)
        (tmp / "sync-functions.h").write_text(production)
        (tmp / "sync-command-stubs.h").write_text(stubs)
        mutations = {
            "acquire-continues": (
                'wlr_log(WLR_ERROR, "Failed to wait for foreign texture DMA-BUF fence");\n\t\t\t\tclose_sync_files(sync_file_fds);\n\t\t\t\treturn false;',
                'wlr_log(WLR_ERROR, "Failed to wait for foreign texture DMA-BUF fence");\n\t\t\t\tclose_sync_files(sync_file_fds);\n\t\t\t\tcontinue;'),
            "publication-ignored": (
                'bool ok = vulkan_sync_render_pass_release(renderer, pass);',
                'bool ok = (vulkan_sync_render_pass_release(renderer, pass), true);'),
            "wait-after-ownership": (
                'stage_submit.waitSemaphoreInfoCount = render_wait_len;',
                'stage_submit.waitSemaphoreInfoCount = 0;'),
            "signal-empty-scope": (
                '.value = render_timeline_point,\n\t\t.stageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT_KHR,',
                '.value = render_timeline_point,\n\t\t.stageMask = 0,'),
        }
        variants = [("plain", production, False), ("asan", production, True)]
        for label, (old, new) in mutations.items():
            if production.count(old) != 1:
                raise RuntimeError(f"mutation anchor changed: {label}")
            variants.append((label, production.replace(old, new), False))
        for label, code, sanitizer in variants:
            (tmp / "sync-functions.h").write_text(code)
            binary = tmp / label
            subprocess.run([
                "cc", "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-DWLR_USE_UNSTABLE",
                "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter", "-g",
                *(["-fsanitize=address,undefined", "-fno-omit-frame-pointer", "-no-pie"] if sanitizer else []),
                "-I" + str(source / "include"), "-I" + str(tmp),
                str(Path(__file__).parent / "fixtures/vulkan-sync.c"),
                str(source / "util/rect_union.c"), str(source / "util/matrix.c"),
                *flags, "-lm", "-o", str(binary),
            ], check=True)
            result = subprocess.run([str(binary)], capture_output=True, text=True,
                preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_CORE, (0, 0)),
                env=dict(env, LD_LIBRARY_PATH=str(prefix / "lib")))
            if label in mutations:
                if result.returncode != -6 or 'Assertion' not in result.stderr:
                    raise RuntimeError(f"regression was not detected: {label}: {result.stderr}")
                print(f"PASS: negative control rejected ({label})")
            else:
                if result.returncode:
                    raise RuntimeError(result.stdout + result.stderr)
                print(result.stdout.strip())
    print("PASS: Vulkan synchronization production functions (plain + ASan/UBSan)")


if __name__ == "__main__":
    main()
