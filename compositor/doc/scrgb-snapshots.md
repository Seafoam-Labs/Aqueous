# Windows-scRGB snapshot regression checks

Predefined Windows-scRGB maps a component value of 1.0 to 80 cd/m². On a PQ
output this mapping must survive snapshot creation, independently of the SDR
white setting. A snapshot has no surface, so the scene buffer owns the mapping
flag. The separate snapshot Auto HDR policy continues to suppress expansion of
client-managed HDR content.

## Automated checks

`scripts/build-wlroots-render-hook.sh` runs `scripts/test-scene-scrgb.py` after
installing the patched library. The fixture uses real color-management wire
requests and surface commits without a GPU. It compiles the production private
luminance helpers directly from the patched sources and checks:

- Live/snapshot equality and the fixed scRGB mapping at several SDR-white levels.
- Ordinary extended-linear SDR and PQ controls, plus SDR-output behavior.
- Pending versus committed descriptions, including metadata-only changes.
- Switching from scRGB to ordinary linear content with identical transfer function
  and primaries, unsetting the description, and preserving frozen state.

To run it separately, supply the patched wlroots source tree and install prefix:

```sh
python3 scripts/test-scene-scrgb.py /path/to/patched/wlroots .deps/wlroots-render-hook
```

From the `compositor` directory, test the actual Zig clone implementation and its
C field offsets:

```sh
export PKG_CONFIG_PATH="$PWD/.deps/wlroots-render-hook/lib/pkgconfig"
export LD_LIBRARY_PATH="$PWD/.deps/wlroots-render-hook/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
zig build test-snapshot -Dllvm=true
```

With the compositor built and a running Wayland session, run the visual checks
serially:

```sh
python3 scripts/test-snapshot-colors.py
python3 scripts/test-snapshot-colors.py --scrgb
```

These nested visual checks use an SDR output; they do not establish physical HDR
correctness. The luminance fixture must fail if the production helper is reverted
to identifying scRGB exclusively through `wlr_scene_surface_try_from_buffer`.

## Physical HDR acceptance

### Vulkan discovery

Windows-scRGB support and `extended_target_volume` are separate capabilities.
The latter permits a parametric target volume to extend beyond the primary
volume; it does not change the predefined Windows descriptor's 80-nit mapping.
Aqueous advertises it only with its scRGB-capable Vulkan-effects path. Mesa's
Wayland WSI requires it to enumerate `VK_COLOR_SPACE_EXTENDED_SRGB_LINEAR_EXT`.

`bash scripts/test-proton-hdr-color-management.sh` checks the advertisement at
versions 1, 2 and 3 and creates/commits extended-linear parametric descriptions
with a 1000-nit target above the default 80-nit primary maximum at v1 and v3.
For a separately built `-Dvulkan-effects=false` compositor, run:

```sh
AQUEOUS_EXPECT_WINDOWS_HDR=0 AQUEOUS_COMPOSITOR_BIN=/path/to/no-effects/aqueous \
  bash scripts/test-proton-hdr-color-management.sh
```

For driver-level verification, build the `vulkan-fallback-demo` branch of
[scRGB-test](https://github.com/kode54/scRGB-test/tree/vulkan-fallback-demo).
Compare `scrgb-test --vulkan` with `scrgb-test --vulkan --assume-scrgb` against
the compositor under test. Both must report FP16 + EXTENDED_SRGB_LINEAR as
available and take the tagged path without needing the workaround. The demo
models Wine's selection: enumeration gates a pass-through swapchain with an
explicit `create_windows_scrgb` description. It does not test every Vulkan
driver's parametric color mapping. Record the driver and whether the output
is SDR or physical HDR when reporting results.

### HDR brightness

Use [scRGB-test](https://github.com/kode54/scRGB-test) on a PQ/HDR output:

1. Compare settled content with snapshot-driven resize, layout/workspace
   transitions, and close animations at SDR-white settings of 80, 200, and 400 nits.
2. Repeat with Auto HDR enabled and disabled. scRGB must retain its fixed mapping.
3. Check ordinary SDR and PQ windows as controls: SDR still follows SDR white;
   PQ must not acquire that gain.
4. Move between SDR and HDR outputs and confirm snapshots match the live content
   on each output.

At 200-nit SDR white the original bug made an scRGB snapshot 2.5 times as bright
as its live surface. There must be no corresponding brightness jump after this
fix.
