# Tiled window drag overlay and animation tutorial

This tutorial adds an input-inert drop preview for every non-floating layout
while preserving Aqueous's current tiled-drag behavior:

- `Super` + left-drag keeps a tiled window tiled.
- Moving over another tiled window shows a translucent drop target.
- `tile`, `monocle`, `grid`, `rows`, `dwindle`, `reverse-dwindle`, and `game-mode` show a
  full-window swap target.
- `scrolling` shows its top, bottom, left, or right insertion zone.
- `composable` delegates same-region behavior to the window's child layout;
  crossing a region boundary exchanges region membership.
- A committed reorder continues to use Aqueous's existing compositor-owned
  window animation.
- The preview eases between targets and fades out on release or cancellation.

The important architectural rule is that policy owns the meaning of a drop,
the scene owns preview nodes, and the output frame loop owns animation time.

```text
pointer motion
    |
    v
wm/Aqueous.zig ---- chooses target and DropZone
    |                         |
    |                         +---- layout/engine.zig mutates layout order
    v
wm/CompositorApi.zig ---- clips preview to its output
    |
    v
DragOverlay.zig ---- moves input-inert scene rectangles
    |
    v
Output.handleFrame() ---- advances preview and Window.anim_tree animations
```

## 1. Build and test the unmodified compositor

Start from the repository root:

```sh
cd compositor
scripts/build-wlroots-render-hook.sh .deps/wlroots-render-hook
export PKG_CONFIG_PATH="$PWD/.deps/wlroots-render-hook/lib/pkgconfig"
zig build test
zig build -Doptimize=ReleaseSafe -Dxwayland -Dllvm
```

Aqueous requires Zig 0.16 or newer. The default build enables both
`-Danimations=true` and `-Dvulkan-effects=true`.

Before editing, read these paths:

- `aqueous/wm/input/drag.zig` selects `swap_tiled` and identifies scrolling
  drop zones.
- `aqueous/wm/Aqueous.zig` starts, updates, validates, and finishes a drag.
- `aqueous/wm/layout/engine.zig` applies swaps or scrolling insertions.
- `aqueous/wm/CompositorApi.zig` is the boundary between pure policy and
  compositor objects.
- `aqueous/Window.zig` owns each window's input-inert animation clone.
- `aqueous/Output.zig` advances animations once per output frame.
- `aqueous/Scene.zig` defines the scene hierarchy.
- `aqueous/fx.zig`, `aqueous/render/EffectMetadata.zig`, and
  `aqueous/render/RoundedPipeline.zig` route rounded scene rectangles through
  Aqueous's Vulkan shaders.

Do not replace the current tiled drag with a floating move. The existing
`pointer_drag.action()` deliberately returns `.swap_tiled` when the window is
tiled and its effective standalone or composable child layout is not
`.floating`.

## 2. Add pure drop-preview geometry

Add this function to `aqueous/wm/input/drag.zig`:

```zig
/// Visualize the user's intent. Scrolling uses the same four regions as
/// dropZone(); other tiled layouts perform a pairwise swap.
pub fn previewGeometry(
    active_layout: layout_config.LayoutId,
    target: types.Rect,
    zone: types.DropZone,
) types.Rect {
    if (active_layout != .scrolling) return target;

    const half_width = @max(1, @divTrunc(target.width, 2));
    const half_height = @max(1, @divTrunc(target.height, 2));
    return switch (zone) {
        .stack_before => .{
            .x = target.x,
            .y = target.y,
            .width = target.width,
            .height = half_height,
        },
        .stack_after => .{
            .x = target.x,
            .y = target.bottom() - half_height,
            .width = target.width,
            .height = half_height,
        },
        .column_before => .{
            .x = target.x,
            .y = target.y,
            .width = half_width,
            .height = target.height,
        },
        .column_after => .{
            .x = target.right() - half_width,
            .y = target.y,
            .width = half_width,
            .height = target.height,
        },
    };
}
```

This is an intent preview, not a second layout engine. A stacked scrolling
column may ultimately divide into thirds or quarters. After the manage cycle
settles, retarget the overlay to the dragged window's authoritative geometry.

Add unit tests beside the existing drag tests:

```zig
test "drop preview uses scrolling insertion regions" {
    const target: types.Rect =
        .{ .x = 100, .y = 50, .width = 300, .height = 180 };

    try std.testing.expectEqual(
        types.Rect{ .x = 100, .y = 50, .width = 300, .height = 90 },
        previewGeometry(.scrolling, target, .stack_before),
    );
    try std.testing.expectEqual(
        types.Rect{ .x = 250, .y = 50, .width = 150, .height = 180 },
        previewGeometry(.scrolling, target, .column_after),
    );
    try std.testing.expectEqual(
        target,
        previewGeometry(.grid, target, .column_after),
    );
}
```

Run the focused test collection:

```sh
zig build test
```

## 3. Create the compositor-owned overlay

Create `aqueous/DragOverlay.zig`. Keep this module independent of policy and
window handles. It only needs:

- the output ID that owns the preview;
- current and target rectangles as floating-point values;
- a current alpha;
- one scene tree;
- a translucent fill rectangle;
- a hollow outline rectangle.

A useful state shape is:

```zig
const DragOverlay = @This();

const std = @import("std");
const build_options = @import("build_options");
const wlr = @import("wlroots");
const fx = @import("fx.zig");

tree: *wlr.SceneTree,
fill: *wlr.SceneRect,
outline: *wlr.SceneRect,

output_id: u64 = 0,
current: [4]f64 = .{ 0, 0, 0, 0 },
target: [4]f64 = .{ 0, 0, 0, 0 },
alpha: f64 = 0,
visible: bool = false,
fading: bool = false,

const move_rate: f64 = 24.0;
const fade_rate: f64 = 18.0;
const epsilon: f64 = 0.02;
const radius: u31 = 12;
const border_width: i32 = 2;
```

Initialize the nodes disabled:

```zig
pub fn init(parent: *wlr.SceneTree) !DragOverlay {
    const tree = try parent.createSceneTree();
    const fill = try tree.createSceneRect(1, 1, &.{ 0.12, 0.55, 1.0, 0 });
    const outline = try tree.createSceneRect(1, 1, &.{ 0.25, 0.72, 1.0, 0 });

    tree.node.setEnabled(false);
    fx.setRectInputEnabled(fill, false);
    fx.setRectInputEnabled(outline, false);
    fx.setRectRadius(fill, radius);

    return .{
        .tree = tree,
        .fill = fill,
        .outline = outline,
    };
}
```

Add these operations:

1. `retarget(output_id, geometry)`:

   - Reject non-positive width or height.
   - On the first target, copy the target into `current`.
   - On later targets, leave `current` unchanged so it eases to the new box.
   - Set `visible = true`, `fading = false`, and enable the tree.

2. `hide()`:

   - Set `fading = true`.
   - Do not disable the tree yet; the frame loop must be able to fade it.

3. `cancel()`:

   - Immediately set `visible = false`, `fading = false`, and `alpha = 0`.
   - Disable the tree. Use this for shutdown, session lock, or invalid output
     teardown where another frame is not guaranteed.

4. `activeFor(output_id)`:

   - Return true when the tree is enabled and its stored output ID matches.

5. `step(output_id, dt_s)`:

   - Ignore a different output ID.
   - Apply frame-rate-independent exponential smoothing:

     ```zig
     const move_t = 1.0 - @exp(-move_rate * dt_s);
     for (&overlay.current, overlay.target) |*value, destination| {
         value.* += (destination - value.*) * move_t;
     }

     const wanted_alpha: f64 = if (overlay.fading) 0 else 1;
     const fade_t = 1.0 - @exp(-fade_rate * dt_s);
     overlay.alpha += (wanted_alpha - overlay.alpha) * fade_t;
     ```

   - Snap values within `epsilon`.
   - Disable the tree after a fade reaches zero.
   - Call a private `apply()` whenever position, size, or alpha changes.
   - Return `true` if scene state changed.

The `apply()` method rounds layout coordinates, updates the tree position, and
sizes both rectangles:

```zig
fn apply(overlay: *DragOverlay) void {
    const x: i32 = @intFromFloat(@round(overlay.current[0]));
    const y: i32 = @intFromFloat(@round(overlay.current[1]));
    const width: i32 =
        @max(1, @as(i32, @intFromFloat(@round(overlay.current[2]))));
    const height: i32 =
        @max(1, @as(i32, @intFromFloat(@round(overlay.current[3]))));

    overlay.tree.node.setPosition(x, y);
    overlay.fill.node.setPosition(0, 0);
    overlay.fill.setSize(width, height);

    const fill_color: [4]f32 =
        .{ 0.12, 0.55, 1.0, @floatCast(0.22 * overlay.alpha) };
    overlay.fill.setColor(&fill_color);
    fx.setRectRadius(overlay.fill, radius);

    if (comptime build_options.vulkan_effects) {
        const bw = border_width;
        overlay.outline.node.setEnabled(true);
        overlay.outline.node.setPosition(-bw, -bw);
        overlay.outline.setSize(width + 2 * bw, height + 2 * bw);
        const outline_color: [4]f32 =
            .{ 0.25, 0.72, 1.0, @floatCast(0.90 * overlay.alpha) };
        overlay.outline.setColor(&outline_color);
        fx.setRectRadius(
            overlay.outline,
            radius + @as(u31, @intCast(border_width)),
        );
        fx.setRectClippedRegion(
            overlay.outline,
            .{ .x = bw, .y = bw, .width = width, .height = height },
            .uniform(radius),
        );
    } else {
        // The stock renderer does not understand Aqueous's hollow-rect
        // metadata. Keep the translucent square fill as the diagnostic
        // fallback instead of rendering the outline as a solid rectangle.
        overlay.outline.node.setEnabled(false);
    }
}
```

If Zig rejects `.uniform(radius)` at that call site, spell it as
`fx.CornerRadii.uniform(radius)`.

Do not attach `SceneNodeData` to this tree. It is visual state, not a surface
or managed window.

## 4. Put the overlay in an input-inert scene layer

Import `DragOverlay.zig` in `aqueous/Scene.zig` and add:

```zig
drag_overlay: DragOverlay,
```

Initialize it under the existing `drag_icons` tree:

```zig
const drag_overlay = try DragOverlay.init(drag_icons);
```

Then include it in `scene.*`.

`Scene.at()` only searches `interactive_tree`; `drag_icons` is a sibling of
that tree. Consequently, an overlay can never become the hit-test result and
hide the tiled window beneath it. This remains true in the
`-Dvulkan-effects=false` diagnostic build, where
`fx.setRectInputEnabled()` is compiled out.

Creating the overlay under `layers.overlay` would be a mistake. That layer is
inside `interactive_tree`, and a plain scene rectangle may terminate wlroots
hit-testing before Aqueous reaches the client window below.

Because `drag_icons` is above the normal scene, cancel the overlay when the
session locks. A direct root-level visual must never survive over a lock
surface. The central drag finish/cancel path should normally handle this; also
call `server.scene.drag_overlay.cancel()` from the lock transition as a
defensive boundary.

## 5. Add narrow compositor API methods

Policy should not import `Scene`, `Output`, or wlroots types. Add methods to
`aqueous/wm/CompositorApi.zig` instead:

```zig
pub fn showTiledDragOverlay(
    _: CompositorApi,
    output_id: u64,
    geometry: layout.Rect,
) void {
    const output = outputById(output_id) orelse return;
    const clipped = intersectRects(geometry, output.policyFullBox()) orelse {
        server.scene.drag_overlay.hide();
        return;
    };
    server.scene.drag_overlay.retarget(output_id, clipped);
    if (output.wlr_output) |wlr_output| wlr_output.scheduleFrame();
}

pub fn hideTiledDragOverlay(_: CompositorApi) void {
    const output_id = server.scene.drag_overlay.output_id;
    server.scene.drag_overlay.hide();
    if (outputById(output_id)) |output| {
        if (output.wlr_output) |wlr_output| wlr_output.scheduleFrame();
    }
}
```

Implement `intersectRects()` as a small pure helper or convert both values to
`wlr.Box` and use `intersection()`. Clipping is required: a scrolling window
can have geometry beyond its output viewport, and the input-inert overlay tree
is global rather than output-local.

Keep these methods intentionally narrow. Do not expose the scene tree or
`DragOverlay` object to policy.

## 6. Connect the overlay to tiled drag motion

In `Aqueous.handlePointerMotion()`, keep the existing `.swap_tiled` validation
order:

1. Find the window under the pointer.
2. Wait for old hit-test geometry to settle.
3. Reject the dragged window itself.
4. Reject non-tiled windows.
5. Reject windows from another output/workspace.
6. Resolve the drop zone.

Immediately after resolving `zone`, show the intent preview:

```zig
const preview = pointer_drag.previewGeometry(
    layout_state.active_layout,
    target.geometry,
    zone,
);
aqueous.api.showTiledDragOverlay(drag.layout_key.output, preview);
```

Then leave the current `layout_engine.drop()`, `awaiting_layout`, and
`requestManageCycle()` calls in place. This preserves live reordering as the
pointer crosses windows.

In the `awaiting_layout` branch, when scene hit-testing finally reports the
dragged window beneath the pointer, retarget the overlay to the authoritative
post-layout geometry before clearing the guard:

```zig
if (target.handle == drag.handle) {
    drag.awaiting_layout = null;
    aqueous.api.showTiledDragOverlay(
        drag.layout_key.output,
        target.geometry,
    );
}
```

Finally, centralize cleanup in `finishInteractiveDrag()`:

```zig
fn finishInteractiveDrag(aqueous: *Aqueous) void {
    const drag = aqueous.drag orelse return;
    if (drag.action == .swap_tiled) {
        aqueous.api.hideTiledDragOverlay();
    } else {
        aqueous.api.endInteractive(drag.handle);
    }
    if (drag.client_seat) |seat| {
        aqueous.api.endClientPointerOperation(seat);
    }
    aqueous.drag = null;
}
```

All cancellation routes should end here, including:

- pointer-button release;
- window destruction;
- invalid workspace or output ownership;
- client maximize, minimize, or fullscreen changes;
- output removal.

Audit every direct `aqueous.drag = null` assignment. Replace bypasses with
`finishInteractiveDrag()` where a drag can actually be active.

## 7. Advance the overlay from the output frame loop

Do not animate from pointer events. Pointer event frequency is unrelated to
the output refresh rate and would make the fade and easing inconsistent.

In `Output.stepAnimations()`, after calculating `dt_s`, advance the overlay
owned by this output:

```zig
if (server.scene.drag_overlay.step(output.policyId(), dt_s)) {
    changed = true;
}
```

In `Output.hasActiveAnimations()`, include it:

```zig
if (server.scene.drag_overlay.activeFor(output.policyId())) return true;
```

This reuses the existing frame scheduling contract:

- `showTiledDragOverlay()` schedules the first frame.
- `hasActiveAnimations()` keeps scheduling frames.
- `stepAnimations()` damages changed scene nodes.
- `renderAndCommit(changed)` renders even if no client buffer changed.
- the loop stops when both window animations and the overlay are idle.

Keep the `dt_s <= 0` first-frame behavior. The next scheduled frame supplies a
real delta. Keep the existing 0.1-second delta clamp as well.

## 8. Reuse the existing window reflow animation

No new tiled-window animation is necessary.

When `layout_engine.drop()` changes layout order, the next manage cycle emits
new placements. `Window.renderFinish()` calls `setAnimationTarget()` for every
visible, non-interactive window. That function:

- immediately moves `window.box`, `tree`, and `popup_tree` to final input
  geometry;
- clones current surface buffers into input-inert `anim_tree`;
- hides live surfaces while the clone is visible;
- eases the clone to the final target in `Window.stepAnimation()`;
- removes the clone after it reaches `fx.anim_epsilon`.

Tiled swap drags intentionally do **not** call `beginInteractive()`, so the
existing animation is not bypassed. Floating move and resize do call it and
continue to track the pointer exactly.

Tune ordinary reflow in `aqueous/fx.zig`:

```zig
pub const anim_rate: f64 = 18.0;
pub const anim_epsilon: f64 = 0.5;
```

Higher `anim_rate` is snappier. Keep exponential smoothing:

```text
t = 1 - exp(-rate * dt)
value += (target - value) * t
```

Do not move live window nodes through intermediate positions. Scene
hit-testing must always use the final layout geometry, or a moving clone can
generate incorrect surface-local pointer coordinates and swap-back loops.

## 9. Create and compile the required shaders

For this feature, the necessary shaders already exist:

- `aqueous/render/shaders/rounded_rect.vert`
- `aqueous/render/shaders/rounded_rect.frag`

Do not create a second Vulkan pipeline just for the drag preview. Calling
`fx.setRectRadius()` or `fx.setRectClippedRegion()` adds effect metadata to the
scene rectangle. The existing path is:

```text
SceneRect
  -> EffectMetadata.RectData
  -> Output.roundedRectHook()
  -> RoundedPipeline.drawRect()
  -> rounded_rect.vert.spv + rounded_rect.frag.spv
```

The vertex shader generates a four-vertex quad from `gl_VertexIndex`, converts
output pixel coordinates to Vulkan clip coordinates, and passes local
rectangle coordinates to the fragment shader.

The fragment shader evaluates a signed-distance rounded box. Its core is:

```glsl
float rounded_box_distance(vec2 position, vec2 size, vec4 radii) {
    vec2 half_size = size * 0.5;
    bool left = position.x < half_size.x;
    bool top = position.y < half_size.y;
    float radius = top
        ? (left ? radii.x : radii.y)
        : (left ? radii.w : radii.z);
    vec2 d = abs(position - half_size) - (half_size - vec2(radius));
    return length(max(d, vec2(0.0))) +
        min(max(d.x, d.y), 0.0) - radius;
}

float coverage(float signed_distance) {
    float aa = max(fwidth(signed_distance), 0.0001);
    return 1.0 - smoothstep(-aa, aa, signed_distance);
}
```

The hollow outline is one rectangle, not four overlapping edges. The fragment
shader computes outer coverage and subtracts inner coverage:

```glsl
output_color = push_data.color * (outer * (1.0 - inner));
```

This prevents seams and gives correct antialiasing at rounded corners.

After editing either GLSL file, regenerate the checked-in SPIR-V from
`compositor/`:

```sh
glslangValidator -V \
  aqueous/render/shaders/rounded_rect.vert \
  -o aqueous/render/shaders/rounded_rect.vert.spv

glslangValidator -V \
  aqueous/render/shaders/rounded_rect.frag \
  -o aqueous/render/shaders/rounded_rect.frag.spv

spirv-val aqueous/render/shaders/rounded_rect.vert.spv
spirv-val aqueous/render/shaders/rounded_rect.frag.spv
```

Those exact commands reproduce the `.spv` files currently checked into this
repository. `build.zig` does not compile GLSL; `RoundedPipeline.zig` embeds the
binary files with `@embedFile()`. Forgetting to regenerate `.spv` produces a
successful build that still runs the old shader.

If you extend the shader's push constants, update all three definitions
together:

1. the GLSL push-constant block in `rounded_rect.vert`;
2. the identical GLSL block in `rounded_rect.frag`;
3. `RectPush` in `RoundedPipeline.zig`.

Every `vec4` occupies 16 bytes here. Update the `@sizeOf(RectPush)` assertion
and the Vulkan push-constant range. Keep the total within the device's
`maxPushConstantsSize`; Vulkan guarantees only 128 bytes.

A pulse does not require shader time. The simpler implementation changes
scene-rectangle alpha in `DragOverlay.step()`, which also gives wlroots correct
damage. Add a shader-specific phase only for a genuinely per-pixel effect such
as moving stripes or a gradient sweep.

## 10. Verify behavior

Run unit and build checks:

```sh
cd compositor
zig build test
zig build -Doptimize=ReleaseSafe -Dxwayland -Dllvm
zig build -Doptimize=ReleaseSafe -Dvulkan-effects=false -Dllvm
```

Then run a nested session:

```sh
cd ..
./launch_river.sh
```

Check each non-floating layout:

1. Open at least three normal windows.
2. Select `tile`, then `grid`, `rows`, `dwindle`, `reverse-dwindle`, `monocle`, and `game-mode`.
3. Hold the configured primary modifier and left-drag over another window.
4. Confirm the overlay never steals hover or blocks another swap.
5. Confirm the overlay stays inside the source output.
6. Confirm windows glide to final layout positions.
7. Release and confirm the overlay fades out.
8. Destroy the dragged window mid-drag and confirm the overlay disappears.
9. Switch workspaces or disable the source output mid-drag and confirm cleanup.
10. Repeat with `scrolling`; verify all four insertion zones and an already
    stacked column.
11. Repeat with `composable`; verify same-region child behavior and a
    cross-region membership exchange.

Also run the renderer regression:

```sh
cd compositor
scripts/test-vulkan-render-seam.sh /tmp/aqueous-vulkan-render-seam
```

For an automated overlay regression, add a small fixture based on
`scripts/test-policy-parity.sh` that:

- maps two high-contrast windows;
- injects a modified left-button drag;
- captures a frame while the pointer is over the target;
- verifies the expected blue pixels are confined to the target output;
- releases the button;
- captures again after the fade deadline and verifies those pixels are gone.

## Completion checklist

- The feature activates only for `.swap_tiled`.
- Floating move and resize behavior is unchanged.
- Overlay nodes are outside `interactive_tree`.
- Preview geometry is clipped to the owning output.
- Layout state remains the source of truth.
- Live window nodes always jump to final input geometry.
- Window clones and overlay nodes animate only from output frames.
- Every drag exit path hides or cancels the overlay.
- Session lock and output destruction cannot leave an overlay visible.
- GLSL and checked-in SPIR-V are updated together.
- Both Vulkan-effects and diagnostic no-effects builds compile.
