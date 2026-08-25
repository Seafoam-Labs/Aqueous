# Firefox invisible on HDR outputs — diagnosis

## Symptom

With HDR enabled on an output, Firefox's window **frame** (Aqueous
decorations, rounded corners) renders, but its **client buffer is absent**:
the window region shows the backdrop blur of the wallpaper behind it. The
blur is of the wallpaper, not of a webpage, which rules out a z-order or
opacity bug — the compositor is drawing around an empty surface.

Firefox's `widget.wayland.vsync.enabled` preference is unrelated; toggling
it does not change the behavior.

## Evidence chain

1. The window is mapped: geometry, decorations, and backdrop blur are all
   correct. Only the client content is missing.
2. Firefox is the only client that implements `wp_color_manager_v1`
   (Firefox 140+). Ghostty, Noctalia, and other common clients do not touch
   it.
3. When the output switches to BT.2020/PQ, wlroots emits
   `image_description_changed` on `wp_color_management_output_v1` and
   Firefox reacts.
4. Aqueous advertises full HDR capability through `wp_color_manager_v1` v3:
   `ext_linear` + `st2084_pq` transfer functions and BT.2020 primaries
   (`compositor/aqueous/Server.zig`, color-manager creation), plus the
   downstream Windows-HDR feature bits
   (`compositor/aqueous/color_management.zig`).
5. Backdrop-blur failures cannot produce this symptom: the blur pipeline
   logs and skips on failure (`compositor/aqueous/Output.zig`, blur marker
   render callback), leaving window content composited normally.

## Candidate root causes

### 1. Firefox switches to a 10-bit/FP16 EGL config that NVIDIA cannot import

Seeing an HDR-capable compositor, Firefox may select a 10-bit or
floating-point EGL visual for the window. On the NVIDIA proprietary driver,
importing those dmabuf formats into the Vulkan renderer is a known failure
class: the buffer never becomes available, the surface stays empty, and the
compositor draws decorations and blur around nothing. Other clients stay
8-bit and are unaffected.

### 2. Color-management feedback stall

Firefox may stall waiting for image-description feedback, or mishandle the
HDR `image_description_changed` transition, and stop committing buffers.

### 3. Explicit-sync interaction

Firefox uses `wp_linux_drm_syncobj_v1`. If the patched wlroots render hook's
timeline handling interacts badly with the 10-bit swapchain, buffer-release
events stop, Firefox exhausts its buffer pool, and commits cease. Same
visible symptom.

## Diagnostic ladder

Run in order; each step narrows the cause.

### Step 1 — compositor log

```sh
tail -f /tmp/aqueous.log
```

Map Firefox with HDR enabled. Look for dmabuf import failures, unsupported
format errors, or protocol errors around the map.

### Step 2 — Firefox protocol trace

```sh
WAYLAND_DEBUG=1 firefox 2>&1 | grep -E "color_manager|image_description|create_params|format|syncobj|commit"
```

Compare HDR on vs off:

- Does Firefox bind `wp_color_manager_v1`?
- Does it request 10-bit/FP16 formats in `zwp_linux_dmabuf_v1.create_params`?
- Do commits stop after the HDR transition?

### Step 3 — disable Firefox color management

`about:config`:

```
gfx.color_management.mode = 0
```

If Firefox reappears with HDR still enabled, the color-management/HDR
interaction is confirmed.

### Step 4 — eliminate the effects pipeline

`~/.config/aqueous/rules.toml`:

```toml
[[window]]
app_id = "firefox"
blur = false
```

Cheaply rules out the Vulkan effects path. Unlikely given the evidence
(blur failures are logged and skipped), but fast to test.

### Step 5 — bisect the render stack

Build the diagnostic stock-wlroots compositor:

```sh
zig build -Dvulkan-effects=false
```

Toggle HDR with that build:

- Firefox renders → the patched wlroots render hook / Aqueous effects stack
  is implicated.
- Firefox still invisible → wlroots-core and Firefox color-management
  interaction.

## Workarounds

### If the color-management interaction is confirmed

Compositor side: add a configuration gate that stops advertising HDR
transfer functions through `wp_color_manager_v1` while keeping the output
HDR for Aqueous's own SDR-to-HDR conversion. Clients then never see an
HDR-capable compositor and keep their 8-bit path. This sacrifices
client-driven HDR (e.g. HDR video in Firefox) until the interaction is
fixed upstream.

Firefox side: keep `gfx.color_management.mode = 0` while HDR is enabled.

### If the NVIDIA format import is confirmed

That is a renderer/driver limitation. The Firefox-side escape hatch is the
color-management preference above (it prevents Firefox from selecting the
HDR EGL config).

## Notes

- The Windows-HDR feature bits advertised by Aqueous are a downstream
  wlroots extension; Firefox only sees the standard `wp_color_manager_v1`
  surface, so the extension bits themselves are not directly visible to it.
- The `widget.wayland.vsync.enabled` preference was ruled out by the user:
  toggling it with HDR on does not change the behavior.
