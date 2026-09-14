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
| Output DMA-BUF and separate cursor sources | Existing `unavailable` behavior |

Pixman does not apply input color transforms. Qualification checks sampled scene
buffers, including cached textures whose original buffers have been released.
Disabled nodes and empty buffer nodes do not contribute. Unknown copy paths
remain unavailable. Scene captures are not native HDR exports.

Protocol `aqueous-capture-color-v1` remains version 1. Its two XML copies are
identical, and the dependency build checks this. Request frame information before
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
