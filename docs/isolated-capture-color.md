# Isolated capture destination colors

Workstream 4 adds destination color metadata to Aqueous's real foreign-toplevel
scene source. It uses the window's separate capture scene. A window covering the
target does not contribute pixels, and the source is never replaced by an output
crop.

The private scene output requires rendering, disabling direct scanout. Its
default destination is sRGB/BT.709 primaries with gamma 2.2 and nominal 80 cd/m²
reference white. A qualification recorded for that render accompanies its frame
through the destination copy. Buffer bit depth does not establish encoding.
Converted SDR frames carry no source HDR mastering or content-light metadata.

| Path | Destination metadata |
| --- | --- |
| Vulkan scene → SHM | SDR, including supported input transfer/gamut conversion |
| Vulkan scene → DMA-BUF | SDR after the default SDR copy render pass |
| Pixman scene → SHM, gamma-2.2/sRGB inputs | SDR |
| Pixman scene with inputs requiring color conversion | `unavailable` |
| Tagged non-SDR single-pixel buffers using the rectangle fast path | `unavailable` |
| Output DMA-BUF, PQ source, 8-bit destination | SDR after PQ decode (renderer with input color transforms) |
| Output DMA-BUF, native/10-bit destination | Source encoding (PQ/BT.2020 or gamma 2.2/sRGB) |
| Separate cursor sources | Existing `unavailable` behavior |

## HDR outputs and 8-bit destinations

8-bit cannot usefully carry PQ. When a PQ output's native buffer is 10-bit, every
8-bit destination (`XRGB8888`/`ARGB8888` and their BGR forms) receives SDR: PQ is
decoded, the output's SDR white returns to 1.0, BT.2020 maps to sRGB, and gamma 2.2
is applied. SHM uses the CPU lookup path; DMA-BUF uses the renderer. A renderer
without input color transforms does not offer 8-bit DMA-BUF formats for PQ
outputs, leaving those clients the converted SHM format. On a PQ output, SHM lists
`XRGB8888` before the native format, because first-pick clients such as grim
cannot describe PQ. 10-bit destinations keep native samples.

## Per-format session description (version 2)

`get_session_info` creates an `aqueous_capture_color_session_v1` for a capture
session. It announces the expected encoding of every offered format code after
creation and after each constraints update, following the session's own `done`.
Output sources report the rules above. Scene sources report SDR when the renderer
supports input and output color transforms; individual frames may still be
`unavailable` (see the table). Per-frame information stays authoritative. The
Aqueous portal uses the session description to set PipeWire `transferFunction`
and `colorPrimaries` on every offered format.

Pixman does not apply input color transforms. Qualification checks sampled scene
buffers, including cached textures whose original buffers have been released.
Disabled nodes and empty buffer nodes do not contribute. Unknown copy paths
remain unavailable. Scene captures are not native HDR exports.

Protocol `aqueous-capture-color-v1` is version 2. Its compositor and wlroots
patch XML copies are identical, and the dependency build checks this. The portal
patch (`packaging/portal/0001-rename-backend-for-aqueous.patch`) carries a third
copy, which must be updated with them. Request frame information before
`capture`. Exactly one `done` or `unavailable` terminates a live metadata object;
successful frames receive that result before `ready`. Metadata is usable only
after a successful frame. Frame/source destruction and failed copies preserve
the terminal-event lifecycle.

Pearl can accept described sRGB-primary gamma-2.2 SDR pixels and convert gamma
2.2 to the sRGB transfer function once when exporting PNG. It must continue to
withhold export for missing or unsupported metadata. This change does not modify
Pearl's client implementation or negotiate a guarantee for every renderer.

Aqueous rejects source creation for unmapped windows or a locked/locking session,
returning an inert source. Existing sources recheck that policy before requesting
and copying a frame. Denied copies fail without touching destination pixels.
Security-context clients continue to lack capture, color and foreign-toplevel
globals. Empty/disabled scene sources and failed renders fail pending captures.

## Validation

From `compositor/`, after building with the patched dependency:

```sh
scripts/test-ext-capture-formats.sh
scripts/test-ext-capture-formats.sh --vulkan /dev/dri/renderD128
python3 scripts/test-scene-capture.py
python3 scripts/test-scene-capture.py --renderer vulkan
```

Use `AQUEOUS_WLROOTS_PREFIX` for a different dependency prefix, and
`--compositor`/`--ctl` for custom binary locations. The native runner creates
private runtime/configuration directories, records logs and window geometry,
starts synthetic headless outputs, and terminates only its own processes.

Verified on 2026-09-14 with wlroots 0.20.2 plus Aqueous patches 0001–0023:

- Full dependency build and its regression checks; compositor build and all
  502 compositor unit tests.
- Pixman and Vulkan scene SHM samples and repeated metadata. Vulkan was exercised
  on the NVIDIA GeForce RTX 5090 via a render-only device.
- Independent ST2084 input encoding and BT.2020-to-sRGB reference matrix. The
  scene renderer maps PQ's 203-nit reference white to SDR white; expected samples
  are gamma-2.2 encoded, with tolerance of three 8-bit codes for PQ quantization
  and renderer precision. SDR samples allow one code on Vulkan, exact on Pixman.
- Separate Vulkan DMA-BUF destination readback matches the SDR palette and
  description. GPU allocation does not support the optional native XR30 output
  fixture on this device; that pre-existing output case reports a skip.
- Bad destination format, disabled source and destruction before ready; metadata
  termination and SHM padding checks.
- Real Pixman and Vulkan compositor captures beneath a raised magenta window;
  repeated captures, lock denial for new/existing sources, unmap denial,
  untouched failed destination buffers, and restricted-client global filtering.

These checks use synthetic surfaces and outputs. They do not accept physical
modesetting, HDR display previews, VRR, mirroring, or crash-safe hardware rollback;
those remain workstream 5.
