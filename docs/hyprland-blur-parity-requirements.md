# Hyprland Blur Parity Requirements

This document describes the work required for Aqueous to match two areas of
Hyprland blur behavior:

1. Blur rules for layer-shell surfaces, their popups, alpha thresholds, and
   xray behavior.
2. Blur appearance controls for noise, contrast, brightness, vibrancy, and
   dark-area vibrancy.

The estimates assume one engineer familiar with Aqueous's rendering and
window-management architecture. They are engineering estimates rather than
delivery commitments.

## Summary

Appearance tuning is relatively contained. Complete layer-shell parity is an
architectural feature because Aqueous currently models blur as an effect owned
by managed windows.

| Target | Approximate effort |
|---|---:|
| Appearance controls only | 1–2 weeks |
| Appearance plus rectangular namespace-based layer blur | 3–5 weeks |
| Add popup blur | 4–7 weeks total |
| Full parity including alpha thresholds and xray | 8–14 engineer-weeks total |

## 1. Appearance tuning

**Status:** Implemented.

Aqueous would need global blur settings similar to:

```toml
[blur]
noise = 0.0117
contrast = 0.8916
brightness = 1.0
vibrancy = 0.1696
vibrancy_darkness = 0.0
```

### Required behavior

- `noise` adds stable visual noise without flickering between frames.
- `contrast` adjusts contrast in the blurred backdrop.
- `brightness` adjusts the brightness of the blurred backdrop.
- `vibrancy` increases the saturation of blurred colors.
- `vibrancy_darkness` controls how much vibrancy affects darker colors.
- Configuration changes take effect through normal hot reload.
- Neutral values reproduce the existing Aqueous output.

### Required implementation work

- Extend blur configuration, validation, hot reload, settings UI, and protocol
  state with the five floating-point fields.
- Pass the resolved values to the blur composite pipeline.
- Extend the composite shader to:

  - multiply brightness;
  - adjust contrast around a defined midpoint;
  - modify saturation using luminance;
  - reduce vibrancy's effect on darker pixels;
  - generate deterministic screen-space noise.

- Decide whether the adjustments operate in linear or perceptual color space.
  Aqueous currently uses a color-managed linear rendering path. Reproducing
  Hyprland's exact appearance may require matching Hyprland's color-space
  behavior rather than merely adding similarly named controls.
- Separate kernel-affecting configuration from appearance-only configuration
  if appearance changes should avoid unnecessarily rebuilding cached blur
  sources.
- Update the embedded shader binaries and pipeline push-constant layout.

### Compatibility defaults

To preserve the existing appearance after an upgrade, the Aqueous defaults
should be:

```toml
noise = 0.0
contrast = 1.0
brightness = 1.0
vibrancy = 0.0
vibrancy_darkness = 0.0
```

Hyprland-like defaults could be supplied as an optional preset instead of
silently changing existing Aqueous configurations.

### Validation

- Parser and range-validation tests for every new setting.
- An exact visual identity check using neutral settings.
- Captures at minimum, maximum, and representative intermediate values.
- Deterministic-noise checks across static frames and partial damage.
- HDR and SDR output validation.
- Fractional-scale and transformed-output captures.
- Cached-versus-uncached blur comparisons.

### Estimate

- Qualitative feature parity: approximately 3–7 engineering days.
- Close visual or numerical parity across color-managed outputs:
  approximately 1–2 weeks.

## 2. Basic layer-surface blur

**Status:** Implemented for namespace-matched rectangular layer surfaces.
Alpha masks, popup inheritance, and xray remain separate later stages below.

The initial useful layer-rule format could be:

```toml
[[layer]]
namespace = "waybar"
blur = true
```

This phase would blur a layer surface's rectangular bounds. It would not yet
provide alpha-shaped masks, popup blur, or xray.

### Rule system

- Add `[[layer]]` entries alongside the existing `[[window]]` rules.
- Match layer-shell namespaces using Aqueous's normal matching conventions.
- Define ordering and conflict resolution when multiple layer rules match.
- Reapply layer rules to existing surfaces after hot reload.
- Preserve safe behavior for invalid configuration updates.
- Add a way to discover layer namespaces, ideally through `aqueousctl`, rather
  than requiring users to inspect debug logs or the raw scene tree.

### Layer-surface state

Every eligible layer surface needs:

- a backdrop-blur handle;
- a blur checkpoint immediately below its content;
- geometry synchronized with anchors, margins, surface size, output, and layer;
- a stable output-cache identity;
- map, unmap, commit, reparent, and destroy handling;
- direct-scanout participation when its blur is visible;
- damage and cache invalidation when its geometry or underlying content changes.

The scene insertion must preserve layer arrangement, focus handling, input
hit-testing, popup placement, and the existing assumptions about direct
children of each layer tree.

### Generic blur ownership

The renderer should be generalized from window-owned blur to generic
backdrop-blur records. A generic record should contain or resolve:

- the owning scene tree;
- the marker node that triggers the blur checkpoint;
- the visible logical geometry;
- corner radii or a square mask;
- enabled state and configuration generation;
- a stable cache key;
- the output intersections on which it is visible;
- optional mask and source-selection behavior for later phases.

The output renderer must iterate all visible blur records rather than only
managed windows. Scene traversal should still determine the actual order in
which blur checkpoints are composited.

### Validation

- Background, bottom, top, and overlay layer surfaces.
- Anchors, margins, exclusive zones, and output reassignment.
- Map, unmap, destroy, and layer changes.
- Multiple overlapping layer surfaces.
- Layers above and below blurred windows.
- Multiple outputs, fractional scaling, and output transforms.
- Screencopy and output-manager commit paths.
- Direct-scanout rejection and restoration.
- Cached-versus-uncached image equivalence.
- Resource cleanup and cache retirement.

### Estimate

Approximately 2–4 weeks, including rule integration, lifecycle handling, and
visual validation.

## 3. Alpha-threshold masks

Hyprland's `ignore_alpha` behavior blurs only pixels whose layer-surface alpha
is above a configured threshold:

```toml
[[layer]]
namespace = "rofi"
blur = true
ignore_alpha = 0.5
```

A rectangular mask is insufficient for this behavior. Aqueous must make the
layer surface's actual pixel alpha available while compositing the blurred
backdrop.

### Rendering options

Two broad approaches are available:

1. Build an alpha-mask texture from the complete layer-surface scene subtree
   and sample it during blur composition.
2. Extend the rendering hook so each surface buffer can composite backdrop blur
   through its own transformed alpha channel.

The selected design must define correct behavior for multiple buffers and
subsurfaces without blurring the layer's own already-rendered content.

### Required coverage

- Fully transparent and semitransparent pixels.
- Threshold boundary behavior.
- RGBX and other effectively opaque buffers.
- Premultiplied alpha.
- Subsurfaces and overlapping buffers.
- Buffer scale, transform, viewport, and crop.
- Fractional output scaling and output rotation.
- Mask changes caused by new commits or damaged buffer regions.
- Cache invalidation when alpha changes without geometry changing.
- Color-managed and HDR surfaces.

### Estimate

Approximately 2–4 additional weeks. This is the highest-risk portion of
layer-surface blur parity.

## 4. Layer popup blur

Layer rules should be able to request blur for XDG popups:

```toml
[[layer]]
namespace = "swaync"
blur = true
blur_popups = true
ignore_alpha = 0.2
```

### Required work

- Generalize XDG popup ownership from window-only ownership to an owner union
  covering windows and layer surfaces.
- Give each eligible popup an independently positioned blur checkpoint.
- Inherit `blur_popups`, `ignore_alpha`, and source-selection behavior from the
  owning layer surface.
- Propagate ownership and effects recursively to nested popups.
- Update existing popups when rules are hot-reloaded.
- Invalidate masks and caches on popup reposition, commit, map, and unmap.
- Retire blur records and resources safely when popups are destroyed.
- Ensure popup blur samples content below the popup and never samples the popup
  itself.

### Estimate

Approximately 1–2 additional weeks after generic layer blur and alpha masking
exist.

## 5. Layer xray

Xray requires a different blur source, not merely another composite-shader
boolean. Normal Aqueous blur samples the actual scene below its checkpoint.
Xray must intentionally exclude selected scene content.

### Behavior definition

Before implementation, pin the target Hyprland version and establish reference
captures that answer:

- Which layer planes are included in an xray source?
- Are managed windows excluded?
- Are lower layer surfaces included?
- How do multiple xray layers interact?
- What happens during workspace transitions and fullscreen presentation?
- How are popups treated?

The Hyprland documentation exposes an xray layer rule but does not fully define
these source-composition details.

### Required implementation work

- Maintain an alternate per-output source representing the agreed xray scene.
- Damage that source whenever included background content changes.
- Allow each blur record to select normal scene-order blur or the xray source.
- Integrate xray source lifetime with output modes, scaling, transforms,
  hotplug, suspend/resume, and renderer reset.
- Ensure normal and xray caches cannot reuse incompatible images.
- Preserve correct behavior across multiple outputs and moving layer surfaces.

### Estimate

Approximately 2–4 additional weeks after generic layer blur exists.

## 6. Configuration and user-facing integration

Full configuration could look like:

```toml
# wm.toml
[blur]
enabled = true
radius = 10
passes = 8
noise = 0.0117
contrast = 0.8916
brightness = 1.0
vibrancy = 0.1696
vibrancy_darkness = 0.0
```

```toml
# rules.toml
[[layer]]
namespace = "waybar"
blur = true
blur_popups = false
ignore_alpha = 0.2
xray = false

[[layer]]
namespace = "rofi"
blur = true
blur_popups = true
ignore_alpha = 0.5
xray = true
```

User-facing work includes:

- annotated examples and a rules reference;
- settings schema fields for global appearance controls;
- rule validation and useful parse errors;
- `aqueousctl` layer namespace inspection;
- debug scene labels for blur owners, masks, and source mode;
- metrics for layer and popup blur checkpoints;
- documentation of build-time Vulkan-effects requirements.

## 7. Test infrastructure

The existing layer-shell test verifies presentation but does not verify blur.
Full parity needs a purpose-built deterministic layer-shell fixture containing:

- a stable namespace;
- opaque, transparent, and semitransparent cells;
- an alpha gradient;
- a desynchronized subsurface;
- an XDG popup and nested popup;
- controlled movement and buffer replacement;
- selectable background, bottom, top, and overlay layers.

The integration matrix should cover:

- rule enable, disable, precedence, and hot reload;
- rectangular and alpha-threshold masks;
- normal and xray sources;
- popup inheritance;
- overlapping windows, layer surfaces, and popups;
- localized damage behind a static layer;
- alpha-only changes in the layer surface;
- cached and uncached blur;
- scales 1, 1.25, 1.5, and 2;
- normal, 90-degree, 180-degree, and 270-degree transforms;
- multi-output placement and movement;
- output disable/resume and atomic mode changes;
- renderer reset and resource teardown;
- screencopy;
- direct-scanout restoration after all visible blur disappears.

## Recommended delivery sequence

1. Add appearance controls with neutral defaults.
2. Generalize window blur records into generic backdrop-blur records.
3. Add namespace rules and rectangular layer-surface blur.
4. Add layer popup ownership and popup blur.
5. Add per-pixel alpha-threshold masks.
6. Add xray using a separately defined source/cache model.
7. Complete the expanded visual and hardware validation matrix.

This order delivers useful user-visible functionality early while isolating
the two highest-risk behaviors—per-pixel alpha masks and xray source
construction—behind an already-generalized blur ownership model.
