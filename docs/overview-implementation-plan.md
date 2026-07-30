# Active-Workspace Window Overview Implementation Plan

## Objective

Implement a compositor-owned, modal window overview for the active workspace
on the selected output.

The overview must not temporarily change layouts or reconfigure clients.
Instead, it renders frozen window thumbnails above the normal scene and changes
focus only after the user confirms a selection.

## Scope

### Included behavior

- Default binding: `Super+W`.
- Target workspace: the active workspace on the focused window's output,
  falling back to the explicitly selected output.
- Include:
  - Tiled windows.
  - Floating windows.
  - Maximized windows.
  - Fullscreen windows.
  - Focusable windows currently outside the scrolling-layout viewport.
- Initial selection: the focused window, or the first eligible window.
- Arrow keys and H/J/K/L navigate spatially.
- Tab and Shift+Tab cycle through the available cards.
- Enter, Space, or left-click confirms the selection.
- Escape or `Super+W` cancels the overview.
- Focus and layout remain unchanged until confirmation.
- The overview remains functional when animations are compiled out; it appears
  immediately in that configuration.

### Excluded behavior

- Minimized windows.
- Windows on inactive workspaces.
- Windows on other outputs.
- Layer-shell surfaces.
- XWayland override-redirect windows.
- Client popups.
- Window titles, application icons, and search.
- Live thumbnail updates while the overview is open.
- A symmetric exit zoom in the initial implementation.

Transient dialogs appear as independent cards initially. They may be grouped
with their parent in a later iteration.

## Architecture

```text
Aqueous policy
  ├─ selects eligible window handles
  ├─ computes the grid and selection
  └─ consumes modal input
              │ value-only API
              ▼
Compositor Overview
  ├─ clones window buffers
  ├─ renders backdrop, cards, and borders
  ├─ scales and crops thumbnails
  └─ animates entry rectangles
              │
              ▼
Output frame loop
```

Policy must never receive scene-node pointers. The compositor visual receives
handles and rectangles through `CompositorApi`.

## 1. Add a pure overview model

Create:

- `compositor/aqueous/wm/overview/model.zig`
- `compositor/aqueous/wm/overview/tests.zig`

Define the core types:

```zig
pub const Card = struct {
    handle: layout.Handle,
    source: layout.Rect,
    target: layout.Rect,
};

pub const State = struct {
    output_id: u64,
    workspace_number: u32,
    original_focus: ?layout.Handle,
    selected: layout.Handle,
    cards: std.ArrayListUnmanaged(Card),
};
```

The module should own these pure operations:

- `arrange(...)`: compute card rectangles.
- `neighbor(...)`: find the nearest card in a direction.
- `cycle(...)`: wrap forward or backward.
- `hitTest(...)`: return the card under a pointer.
- `remove(...)`: remove a disappearing window and choose a replacement
  selection.
- `contains(...)`: validate selection handles.

### Grid algorithm

Use the output's usable area for cards and its full area for the dim backdrop.

For every possible column count from `1...window_count`:

1. Compute `rows = ceil(window_count / columns)`.
2. Divide the usable area into equal cells with fixed outer and inner gaps.
3. Aspect-fit each source rectangle into its cell.
4. Score the candidate using total displayed thumbnail area.
5. Penalize empty cells and very narrow thumbnails.
6. Choose the highest-scoring grid deterministically.

This produces better results than always using `ceil(sqrt(n))`, especially when
the workspace contains several portrait or ultrawide windows.

Preserve the filtered `output.windows` order when assigning cells. Navigation
should use card-center geometry rather than array order.

### Model tests

Cover:

- Empty, single-window, and large-window-count inputs.
- Output rectangles with non-zero origins.
- Portrait, landscape, and mixed aspect ratios.
- All cards contained within the usable area.
- No card overlap.
- Stable output for identical input.
- Directional navigation.
- Tab wrapping.
- Pointer hit-testing.
- Selection replacement after removing the selected card.

## 2. Add compositor-owned overview rendering

Create:

- `compositor/aqueous/Overview.zig`

Add an `Overview` field to `compositor/aqueous/Server.zig`. Initialize it after
`Scene` and destroy it before the root scene.

Suggested visual API:

```zig
pub fn show(
    overview: *Overview,
    output_id: u64,
    output_box: wlr.Box,
    cards: []const Card,
    selected: layout.Handle,
) !void;

pub fn setSelected(overview: *Overview, handle: layout.Handle) void;
pub fn remove(overview: *Overview, handle: layout.Handle) void;
pub fn hide(overview: *Overview) void;
pub fn step(overview: *Overview, output: *Output, dt_s: f64) bool;
pub fn activeOn(overview: *const Overview, output_id: u64) bool;
pub fn animatingOn(overview: *const Overview, output_id: u64) bool;
```

### Scene structure

Create one disabled tree as the last child of `scene.normal_tree`, making it
topmost among ordinary unlocked-session content:

```text
overview tree
  ├─ dim backdrop
  ├─ card 1
  │   ├─ cloned surface buffers
  │   └─ selection border
  ├─ card 2
  └─ ...
```

The backdrop should cover only the owning output. It should block normal scene
hit-testing while policy performs custom card hit-testing.

Do not attach `SceneNodeData` to thumbnail nodes. They must remain input-inert.

### Thumbnail capture

Use the existing cloning path in `compositor/aqueous/Scene.zig`, but add a
narrow public method to `compositor/aqueous/Window.zig` that:

1. Temporarily removes layout and content clipping.
2. Clones the complete surface buffer tree.
3. Restores the original clip immediately.
4. Reports each clone's original position, destination size, source box, and
   transform.

Immediate restoration matters because overview entry occurs outside the normal
render-finish path.

Each overview card should retain records similar to the existing animation
buffer records:

```zig
const BufferRecord = struct {
    node: *wlr.SceneBuffer,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    source: wlr.FBox,
    transform: wl.Output.Transform,
};
```

Scale every buffer's position and destination size relative to the window's
source rectangle. Preserve its source box and transform. Crop against the card
rectangle using the same transformed-source calculations currently used for
animated viewport clipping in `Window.updateAnimationClip()`.

Keep this implementation separate from normal `anim_tree` initially. Reusing
`anim_tree` would create conflicts with window and workspace animations.

### Visual cleanup

`show()` must be transactional:

- Build entries under a disabled tree.
- On allocation or cloning failure, destroy all partial nodes.
- Enable and raise the tree only after every usable entry is ready.
- If one individual window cannot be cloned, skip it and report the handle to
  policy.
- If no entries remain, return an error and leave the overview inactive.

Destroying an entry must release all cloned buffer references and effect
metadata.

## 3. Add the policy-to-compositor API

Extend `compositor/aqueous/wm/CompositorApi.zig` with value-only operations:

```zig
pub fn showOverview(cards: []const overview.Card, ...) !void;
pub fn updateOverviewSelection(handle: layout.Handle) void;
pub fn removeOverviewWindow(handle: layout.Handle) void;
pub fn hideOverview() void;
pub fn refreshPointerFocus() void;
pub fn sessionUnlocked() bool;
```

`refreshPointerFocus()` should call `cursor.updateState()` after the overview
disappears so pointer focus is restored without requiring physical pointer
movement.

Add an output animation query through `server.overview`; do not expose
`Overview` or scene nodes to policy.

## 4. Add overview state to Aqueous

Add an optional logical state to `compositor/aqueous/wm/Aqueous.zig`:

```zig
overview: ?overview_model.State = null,
```

Implement:

- `toggleOverview()`
- `openOverview()`
- `cancelOverview()`
- `confirmOverview()`
- `moveOverviewSelection(dx, dy)`
- `cycleOverviewSelection(delta)`
- `updateOverviewHover(x, y)`

### Entry flow

`openOverview()` should:

1. Require integrated policy mode.
2. Require an unlocked session.
3. Reject entry during an interactive drag.
4. Reject entry while a layer-shell or other non-window surface owns keyboard
   focus.
5. Resolve the selected output and active workspace.
6. Build a policy snapshot.
7. Filter `output.windows` by:
   - Matching active workspace.
   - `accepts_focus == true`.
   - State is not minimized.
   - Geometry has positive dimensions.
8. Compute grid targets.
9. Select the currently focused handle if eligible.
10. Ask the compositor to construct the visual.
11. Store logical state only after visual creation succeeds.
12. Suppress pointer constraints.
13. Schedule a frame on the owning output.

Zero eligible windows should be a quiet no-op.

### Exit flow

Cancellation should:

1. Destroy the visual.
2. Free logical card storage.
3. Re-enable pointer constraints.
4. Refresh pointer focus.
5. Preserve the original keyboard focus.

Confirmation should:

1. Copy the selected handle.
2. Destroy the overview and restore input state.
3. Validate that the handle still exists on the same active workspace.
4. Request focus through the normal policy path.

Using the normal focus path ensures that:

- The scrolling layout reveals or recenters off-screen selections.
- Floating windows are raised normally.
- Focus history remains consistent.
- Focus-sensitive opacity and borders update normally.

## 5. Add modal keyboard handling

Add `toggle_overview = "Super+W"` to:

- `compositor/aqueous/wm/config/actions.zig`
- `plugin/helper/src/schema.zig`
- `wm.toml`

Add the builtin dispatch in `Aqueous.runBuiltin()`.

At the start of `Aqueous.handleKey()`:

1. If no overview is active, use normal binding resolution.
2. If active, interpret overview keys before ordinary bindings.
3. Return `true` for every key press handled by the modal.
4. Also consume unrelated non-modifier keys so they cannot reach clients.

Mappings:

| Input | Result |
|---|---|
| Left / H | Select left |
| Right / L | Select right |
| Up / K | Select above |
| Down / J | Select below |
| Tab | Next |
| Shift+Tab | Previous |
| Enter / Space | Confirm |
| Escape | Cancel |
| `toggle_overview` binding | Cancel |

The existing keyboard consumer tracking will route releases consistently
because overview presses are recorded as policy-consumed presses.

Do not change keyboard focus on entry. Modal consumption is sufficient and
avoids a needless focus leave/enter sequence.

## 6. Add pointer interaction

Modify the existing Aqueous pointer hooks rather than attaching input data to
overview thumbnails.

### Motion

At the beginning of `handlePointerMotion()`:

- If overview is active, hit-test its cards.
- If the pointer enters a new card, update logical and visual selection.
- Return without executing drag behavior.

Normal `Cursor` scene hit-testing will encounter the input-blocking overview
layer and clear client pointer focus.

### Buttons

At the beginning of `handlePointerButton()`:

- While overview is active, consume all left-button press and release events.
- Confirm the hovered card on either left press or release; choose one
  convention and test it.
- Consume other buttons without forwarding them to clients.
- Do not require the normal primary modifier.

Click confirmation should use the same exit-and-focus path as Enter.

## 7. Handle animation conflicts

Before cloning thumbnails, settle or cancel animations on the owning output:

- Cancel any active workspace transition.
- Tear down ordinary window animation clones.
- Restore live-window opacity.
- Leave windows at their already-authoritative target geometry.

Add a narrow `Output.prepareOverview()` or equivalent compositor method. Do not
let overview capture transparent live buffers while an `anim_tree` is presenting
the visible content.

This should snap only cosmetic animation state; it must not alter layout or
focus.

## 8. Add the overview entry animation

Implement static rendering first, then add the zoom.

For each card:

- `start_rect`: current full window geometry.
- `target_rect`: overview grid rectangle.
- `current_rect`: interpolated rectangle.
- `progress`: shared entry-animation progress.

Animate:

- Window rectangle from `start_rect` to `target_rect`.
- Buffer positions and destination sizes from the corresponding scale.
- Backdrop alpha from `0` to the configured dim value.
- Selection border with the current animated card rectangle.

Use the existing frame-rate-independent smoothing style. Extend
`compositor/aqueous/Output.zig` so:

- `stepAnimations()` also calls `server.overview.step(output, dt_s)`.
- `hasActiveAnimations()` includes
  `server.overview.animatingOn(output.policyId())`.
- Frames continue to be scheduled while either ordinary or overview animation
  is active.

When animations are compiled out:

- `show()` places cards at target rectangles immediately.
- `step()` returns false.
- No behavior or input functionality is lost.

For the initial release, cancellation and confirmation can remove the overview
immediately. A symmetric exit zoom can be added later without blocking the core
feature.

## 9. Add lifecycle and invalidation rules

The initial overview membership should be frozen. Avoid rebuilding thumbnails
while active.

Handle these events:

- Window destroyed:
  - Remove its logical and visual card.
  - If selected, select the nearest remaining card.
  - Close if no cards remain.
- New window admitted:
  - Cancel the overview. The new surface may not have a committed buffer yet.
- Window moved off the workspace:
  - Cancel the overview during the next manage-cycle validation.
- Active workspace changed externally:
  - Cancel before applying the new workspace scene.
- Owning output disabled, destroyed, or reconfigured:
  - Cancel immediately.
- Configuration reload:
  - Cancel before replacing bindings.
- Session lock:
  - Cancel before disabling `normal_tree`.
- Compositor shutdown:
  - Hide and deinitialize the overview before destroying the scene root.

Extend `Aqueous.forgetWindow()` for window removal. Add a corresponding
output-forget hook because the feature stores an output ID and geometry.

Every public close path should be idempotent.

## 10. Add documentation and settings

Update:

- `wm.toml`: document `toggle_overview`.
- `README.md`: mention the workspace-local overview.
- `docs/compositor-interactions.md`: document modal input and frozen-buffer
  ownership.
- `plugin/helper/src/schema.zig`: expose the binding in settings.

Keep visual constants centralized in `Overview.zig` initially:

- Outer margin.
- Card gap.
- Backdrop opacity.
- Selection border width and color.
- Animation rate.

Avoid adding a full `[overview]` configuration section until the interaction
and visuals stabilize.

## 11. Verification plan

### Unit tests

Add the pure overview model suite to `zig build test`.

Extend action and configuration tests for:

- Default `Super+W`.
- User override.
- Explicit unbind.
- Duplicate binding resolution.

### Headless integration test

Add:

- `compositor/scripts/test-overview.sh`

The test should:

1. Start one headless output.
2. Launch three distinctly colored windows.
3. Record window geometry, workspace, layout, and focus.
4. Trigger `Super+W`.
5. Verify the scene contains an enabled overview tree and three cards.
6. Capture a screenshot and confirm all three colors appear in separated
   thumbnail regions.
7. Verify window geometry and workspace data did not change.
8. Navigate and confirm with Enter.
9. Verify focus changed to the selected window.
10. Reopen, press Escape, and verify focus did not change.
11. Reopen, move the pointer to a card, click, and verify focus.
12. Close a window while overview is active and verify clean removal.
13. Lock or disable the output while active and verify no overview nodes
    survive.

Add a scrolling-layout case with enough columns to make one window off-screen.
The overview must include it, and confirming it must cause the normal scrolling
layout to reveal it.

### Regression gates

Run:

- `zig build test`
- A normal optimized compositor build.
- A build with animations disabled.
- The existing scrolling-viewport render test, because thumbnail capture
  touches window clipping.
- The Pixman headless overview test.
- A Vulkan/effects smoke test to catch cloned-buffer metadata or cleanup
  problems.
- Leak and scene inspection after repeatedly opening and closing the overview.

## Completion criteria

The feature is complete when:

- `Super+W` displays every eligible window from only the active workspace on
  one output.
- Opening the overview sends no client resize or configure and changes no
  layout geometry.
- All navigation input is compositor-consumed.
- Escape preserves focus.
- Enter and click focus exactly the selected window.
- Off-screen scrolling windows can be selected and revealed.
- Other outputs and workspaces are unaffected.
- Pointer constraints are restored correctly.
- Locking, window destruction, output loss, and reload leave no stale nodes.
- Both animated and non-animated builds work.
- Repeated entry and exit produce no buffer, effect-metadata, or allocator
  leaks.

## Recommended implementation sequence

1. Pure model and unit tests.
2. Static compositor visual.
3. Policy entry, cancellation, and confirmation.
4. Modal keyboard navigation.
5. Pointer hover and click.
6. Lifecycle cleanup.
7. Headless static integration test.
8. Entry animation.
9. Animation-disabled and Vulkan regression coverage.
10. Documentation and settings exposure.

This sequence keeps the static functional overview independently testable
before adding animation complexity.
