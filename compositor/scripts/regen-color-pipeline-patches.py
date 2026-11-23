#!/usr/bin/env python3
"""Regenerate 0047 (FMT switch amendment) and create 0050 (cursor GPU copy),
then verify the full series reproduces the working tree exactly."""
import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path("/home/chris/Source/Repos/Aqueous")
PATCHES = REPO / "compositor/patches/wlroots"
WORK = REPO / ".qwen/tmp/wlroots-work"
BASE47 = pathlib.Path("/tmp/aq-base47")
BASE50 = pathlib.Path("/tmp/aq-base50")
TARBALL = REPO / "compositor/.deps/downloads/wlroots-0.20.2.tar.gz"

FMT_FILES = ["backend/drm/color_pipeline.c", "include/backend/drm/color_pipeline.h"]
CURSOR_FILES = ["types/output/cursor.c", "render/vulkan/renderer.c",
                "render/vulkan/texture.c", "render/vulkan/copy.c",
                "include/render/vulkan.h", "backend/drm/atomic.c",
                "backend/drm/fb.c", "types/scene/wlr_scene.c",
                "backend/drm/drm.c", "include/backend/drm/drm.h"]


def diff_file(base, work, rel, context=3):
    r = subprocess.run(["diff", f"-U{context}", "--label", f"a/{rel}", "--label", f"b/{rel}",
                        str(base / rel), str(work / rel)], capture_output=True, text=True)
    if r.returncode not in (0, 1):
        sys.exit(f"diff failed for {rel}: {r.stderr}")
    return r.stdout


def apply_patch(tree, patch_path, fuzz=0):
    r = subprocess.run(["patch", "--batch", "--forward", f"--fuzz={fuzz}", "-p1", "-s"],
                       cwd=tree, stdin=open(patch_path), capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"patch {patch_path} failed on {tree}:\n{r.stdout}\n{r.stderr}")


def extract(tree):
    subprocess.run(["tar", "-xzf", str(TARBALL), "--strip-components=1", "-C", str(tree)],
                   check=True)


def apply_series(tree, patches):
    for p in patches:
        apply_patch(tree, p)


# Script order: the two 0020 patches are sync-failure-handling then submit-dependencies.
def series_up_to(n):
    out = []
    for p in sorted(PATCHES.glob("0*.patch")):
        num = int(p.name[:4])
        if num > n or p.name.startswith("0020-vulkan-submit-dependencies"):
            continue
        out.append(p)
        if p.name.startswith("0020-vulkan-sync-failure-handling"):
            out.append(PATCHES / "0020-vulkan-submit-dependencies.patch")
    return out


# 1. Isolate the FMT delta (work vs original full series) for the two files.
# Minimal context: nearby hunks must not merge across 0048/0049-added lines
# that are absent in the 0047-only tree the delta is applied to.
fmt_delta = "".join(diff_file(BASE50, WORK, rel, context=1) for rel in FMT_FILES)
delta_path = pathlib.Path("/tmp/aq-fmt.delta")
delta_path.write_text(fmt_delta)

# 2. treeA47 = original 0001-0047 state + FMT delta. Recover the original
# 0047 state deterministically by reversing 0049/0048 from base50 (the repo
# 0047 may already be amended from a previous run).
treeA47 = pathlib.Path("/tmp/aq-treeA47")
shutil.rmtree(treeA47, ignore_errors=True)
shutil.copytree(BASE50, treeA47)
for name in ("0049-scene-post-blend-cursor.patch", "0048-color-pipeline-post-blend-encode.patch"):
    r = subprocess.run(["patch", "--batch", "-R", "--fuzz=0", "-p1", "-s"],
                       cwd=treeA47, stdin=open(PATCHES / name), capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"reverse {name} failed:\n{r.stdout}\n{r.stderr}")
apply_patch(treeA47, delta_path, fuzz=1)

# 3. New 0047 = diff(base47, treeA47); keep the original description, extend it.
orig47 = (PATCHES / "0047-drm-color-pipeline-nvidia-planner.patch").read_text()
desc47 = orig47[:orig47.index("--- a/")]
desc47 = desc47.split("\nThe FMT-inert assumption")[0]
if not desc47.endswith("\n"):
    desc47 += "\n"
desc47 += ("\nThe FMT-inert assumption for FP16 is now switchable:\n"
           "AQUEOUS_DRM_COLOR_PIPELINE_FP16_FMT=1 (drm_color_pipeline_set_fp16_fmt)\n"
           "treats the leading FMT matrix as effective, letting gain-folded matrices\n"
           "resolve on the FMT-only FP Lite pipeline. The default stays conservative:\n"
           "an inert FMT silently drops the placed stage, so the assumption must be\n"
           "pixel-verified before it can become a default.\n")
body47 = "".join(diff_file(BASE47, treeA47, rel) for rel in FMT_FILES)
(PATCHES / "0047-drm-color-pipeline-nvidia-planner.patch").write_text(desc47 + body47)

# 4. New 0050 = diff(base50, work) for the cursor-fix files.
desc50 = """cursor, vulkan: hardware cursor via GPU copy onto LINEAR-only planes

nvidia cursor planes scan out ARGB8888+LINEAR only, and the Vulkan device
reports no color-attachment features for LINEAR, so the cursor format
picker's render/display modifier intersection is empty and every output
falls back to a software cursor. A visible software cursor disables direct
scan-out permanently, which also blocks the color-pipeline scanout path.

The cursor picker now falls back to the display format when the renderer
is Vulkan and the intersection is empty. The render pass serves such
non-renderable dmabuf targets with a GPU copy variant of the existing
copy_target machinery: it renders into an internal tiled image (the color
transform stays in the render pass) and copies into the imported LINEAR
dmabuf with vkCmdCopyImage in the same submission. No host memory or CPU
conversion is involved; finish waits for pass completion so the cursor
buffer is ready before the atomic commit. vulkan_import_dmabuf takes an
explicit image usage so the destination can be imported TRANSFER_DST-only.

The CPU presentation-copy path is unchanged. Any allocation or import
failure keeps the existing software-cursor fallback.

With the hardware cursor live, direct scan-out is unblocked, which exposed
a second nvidia behavior: FB imports of non-FP16 formats are rejected while
an FP color pipeline is bound on the plane. The pipeline unbind rides the
same atomic commit as the new FB, whose import happens first, so the first
integer import after FP16 scan-out deadlocks and loops into unbounded buffer
reallocation. On a failed connector prepare with a committed pipeline,
commit the unbind alone (current FB and gamma stay one frame) and retry the
import once. FB import failures now log the format and modifier.

The post-blend cursor luminance scale is corrected: the encode LUT maps
input 1.0 to the output peak, so cursor white lands at scene SDR diffuse
white (sdr_white_level, else the transfer reference) over peak, instead of
the wire scale reference/max which displayed ~25x too dark.

Two robustness fixes for the DPMS sleep/wake DMA wedge observed on nvidia
620 (flip-event desync WARN, then permanent nvCtxDmaAlloc failure):

- On output disable the scene previously did nothing, keeping stale
  post-blend state and a cached encode LUT across sleep; the wake could
  borrow a gamma blob the disable commit freed. The disable path now
  disengages post-blend and drops the cached encode LUT and previous
  transforms so the wake rebuilds gamma from clean state.

- A wedged kernel drove an unbounded commit-retry spin (~95% CPU, hundreds
  of thousands of failed imports, journal flood). Consecutive non-test
  commit failures now trigger a cooldown that skips the expensive
  prepare/commit (and dumb-buffer reallocation) until it expires, then
  probes again; any success resets the counter.
"""
body50 = "".join(diff_file(BASE50, WORK, rel) for rel in CURSOR_FILES)
(PATCHES / "0050-cursor-linear-gpu-copy.patch").write_text(desc50 + body50)

# 5. Verify: fresh tree + full amended series == working tree.
verify = pathlib.Path("/tmp/aq-verify")
shutil.rmtree(verify, ignore_errors=True)
verify.mkdir()
extract(verify)
series = series_up_to(49) + [PATCHES / "0050-cursor-linear-gpu-copy.patch"]
apply_series(verify, series)
r = subprocess.run(["diff", "-r", "-x", "*.orig", "-x", "*.rej", str(verify), str(WORK)],
                   capture_output=True, text=True)
if r.returncode != 0:
    print(r.stdout[:4000])
    sys.exit("VERIFY FAILED: series does not reproduce the working tree")
print("OK: 0047 amended, 0050 created, full series reproduces the working tree")
