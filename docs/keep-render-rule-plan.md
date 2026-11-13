# Plan: `keep_render` window rule

Status: proposed. No code changes yet.

## Goal

A boolean window rule that keeps a matched window receiving Wayland frame
callbacks while it is hidden (inactive workspace, minimized, overview-hidden,
output off/locked), so games keep rendering in the background instead of
throttling. Today, hidden windows get their scene nodes disabled
(`Window.zig` `renderFinish`, ~1861–1913) and
`wlr_scene_output_send_frame_done` (`Output.zig:2348`) never reaches them.

## TOML syntax

```toml
[[window]]
app_id = "steam_app_*"      # or class = "…" for Xwayland
keep_render = true
```

- Boolean, default `false`, managed scope only.
- Valid on `content_type = "game"` rules: treated as a rendering/client-buffer
  effect like `blur`/`hdr_expand` (kept on the content-type visual-only resolve
  path; placement edits still dropped).
- Rejected in `scope = "override_redirect"` rules (atomic rejection, existing
  `unsupported_popup_key` mechanism).
- Integrated policy only (rules do not run in external-WM mode).

Semantics: kept windows receive frame callbacks at ~60 Hz while the scene is
not delivering to them, and are never sent the xdg `suspended` state. Scene
nodes stay disabled — the window is not composited, shown, or made eligible
for screencopy/mirrors/overlay planes.

## Delivery mechanism: global 60 Hz timer + direct `sendFrameDone`

Rejected alternatives:

- **Render-loop send** (overview precedent, `Output.zig:2350–2356`):
  `handleFrame` only re-arms via `scheduleFrame()` when
  `hasActiveAnimations()`; with no damage/animations the loop idles and kept
  windows stall. It also paces at panel refresh (144–240 Hz → unbounded client
  FPS, battery cost) and fails entirely with all outputs off.
- **Enabled-but-offscreen nodes**: violates the codebase invariant that
  inactive-workspace windows must never stay enabled; leaks windows into
  screencopy/mirrors/overview/overlay-plane eligibility; wlroots may
  region-cull offscreen nodes in `send_frame_done` anyway.

Chosen: **one wl_event_loop timer** (16 ms, one-shot, re-armed per tick),
armed whenever any kept mapped window exists. It is the pacing source,
independent of output state — works when all outputs are idle, disabled,
DPMS-off, locked, or the session is inactive. Precedents: overview's direct
`window.sendFrameDone()` and the hidden-FIFO 40 Hz timer in
`patches/wlroots/0040-hidden-fifo-pacing.patch`.

Per-tick predicate (new `Window.keepRenderNeedsFrameDone()`):

```zig
if (!window.keep_render or window.state != .mapped or window.impl == .destroying) return false;
if (window.rootSurface() == null) return false;
if (!window.tree.node.enabled) return true;               // hidden/minimized/inactive ws/overview
if (server.lock_manager.state != .unlocked) return true;  // normal_tree disabled while locked
if (server.session) |s| if (!s.active) return true;
const ws = window.workspace orelse return true;
const out = ws.output;
const wlr_out = out.wlr_output orelse return true;
if (!wlr_out.enabled or out.current.state != .enabled) return true;
return false; // visible on a live output: the scene already paces it
```

Using `tree.node.enabled` (the `presenting` flag) means outgoing windows
during workspace slides stay scene-paced — no double rate. Frame callbacks
are one-shot per commit, so delayed ticks cannot burst.

## Changes, in implementation order

### 1. Rule engine — `compositor/aqueous/wm/rules/engine.zig`

- `Rule` (~line 139, near `skip_taskbar`): add `keep_render: bool = false`.
- `Rule.fingerprint()`: hash the new field (edits must reconcile).
- `Rule.floatingFingerprint()` (line 220, placement-only stripping): clear
  `keep_render` (it is an effect, not geometry).
- `matcherFingerprint()`: unchanged (effect, not matcher).
- `resolve()` content-type visual-only path: keep `keep_render`; update the
  `content_type` doc comment's effect list.

### 2. TOML parsing — `compositor/aqueous/wm/rules/config.zig`

- `applyValue()`: parse `keep_render` via existing `parseBool` (invalid values
  keep the default, matching existing bools).
- `overrideRedirectKey()`: do **not** add the key — `appendValid()` then
  rejects it atomically for OR scope via `error.UnsupportedOverrideRedirectRule`.

### 3. Window state — `compositor/aqueous/Window.zig`

- Field `keep_render: bool = false` near `hdr_expand_rule` (line 324).
  - Not `PolicyState`: no manual user toggle, so no owned/overridden lifecycle;
    recomputed each manage cycle like visuals.
  - Not `rendering_requested`: that is the scene contract; `keep_render`
    changes callback delivery, not scene state. (Optional: add to
    `policyTrace` for diagnostics — churns trace fingerprints; skip in v1.)
- **Critical**: `shouldSuspend()` (line 1436): early
  `if (window.keep_render) return false;`. Without this, cooperative clients
  stop rendering on the xdg `suspended` configure state regardless of
  callbacks. `refreshSuspension()` already dirties windowing on change, so
  reloads auto-send the clearing configure. Xwayland unaffected.
- New `keepRenderNeedsFrameDone()` helper near `sendFrameDone()` (line 2534).

### 4. Application hook — `wm/CompositorApi.zig` + `wm/Aqueous.zig`

- `CompositorApi.applyKeepRender(handle, bool)` beside `applyRuleVisual`
  (line 1188) → sets `window.keep_render`.
- Call it in `reconcileRulePlacements()` (`Aqueous.zig:3500`) right after
  `rules.resolve(...)`, **before** the placement-fingerprint `continue`.
- Why this pass: the main manage snapshot is active-workspace-only, so the
  `applyRuleVisual` second pass (`Aqueous.zig:614`) misses inactive-workspace
  windows — the target case. `reconcileRulePlacements` consumes
  `rulePlacementSnapshot` (`CompositorApi.zig:826`, `include_inactive=true`),
  covering active + inactive + minimized + soft-disabled-output windows. It
  runs every manage cycle; both reload paths (`reload_rules` builtin, file
  watcher) and property changes converge on `requestManageCycle()`, giving
  automatic re-evaluation on reload/title/tag/content-type changes. The value
  is overwritten unconditionally each cycle — no `prepareWindowRuleMatch`
  reset needed.

### 5. Timer — `compositor/aqueous/wm/Aqueous.zig`

- Field `keep_render_timer: ?*wl.EventSource = null` beside `reload_timer`;
  create in `init()`, remove in `deinit()` (existing timer patterns).
- `syncKeepRenderTimer()`: arm 16 ms if any window has
  `keep_render and state == .mapped`, else disarm. Call at end of
  `applyManageCycle()`.
- `handleKeepRenderTimer()` (model: `handleRuleStartupTimer`): iterate
  `server.wm.windows`, call `window.sendFrameDone()` where
  `keepRenderNeedsFrameDone()`; disarm if no kept mapped windows remain
  (self-heal), else re-arm 16 ms (Wayland timers are one-shot).

### 6. Overview single-source fix — `compositor/aqueous/Output.zig`

- In `handleFrame()`'s deck block (2350–2356), skip `window.keep_render`
  entries — the timer already keeps them live; avoids refresh-rate + 60 Hz
  double pacing.

### 7. Settings schema — `settingsApplication/src/backend/collection_schema.zig`

- Add `"keep_render"` to `rule_keys` (line 18) and the `ruleBoolean` list
  (line 69). Check `tests/backend/test-config.sh` and `tests/fixtures/rules.toml`.

## Edge cases

- **Closing/unmapped/destroying**: `sendFrameDone` asserts `.mapped`; the
  predicate guards state/impl/rootSurface (Xwayland root can be null unmapped).
- **Workspace slides**: outgoing nodes enabled → scene paces; after settle,
  nodes disable → timer takes over with no gap (timer already armed).
- **Minimize / overflow transfer / shell `.hide`**: all funnel to disabled
  nodes → timer delivers.
- **Session lock**: `normal_tree` disabled → scene delivers nothing; timer
  delivers to kept windows. Opt-in GPU use while locked; no content leak.
- **All outputs idle/disabled/DPMS-off/unplugged**: predicate covers
  null/disabled `wlr_output` and `current.state != .enabled`; the tick reads
  live state, not stale snapshots.
- **Mirrors**: irrelevant — direct surface send bypasses mirror logic.
- **Xwayland**: works via `rootSurface()` (overview precedent); no suspended
  state; OR scope rejects the key.
- **Popups/subsurfaces**: v1 covers the root surface only (same as
  `Window.sendFrameDone`); document.
- **FIFO clients**: patch 0040 paces hidden FIFO surfaces at 40 Hz
  independently of callbacks → hidden FIFO games get ≤40 fps. Acceptable;
  document; optional follow-up to teach the patch about kept surfaces.
- **Buffer release**: continuous hidden commits must not stall on unreleased
  buffers — validate with the retention probe.

## Tests

Unit (`zig build test`; reaches `rules/config.zig` via
`aqueous/config_tests.zig` → `wm/config_tests.zig`, and `engine.zig` via
`wm/rules/tests.zig`):

- Parse true/false; invalid value keeps default; first-match-wins.
- `fingerprint()` changes on edit; matcher/placement fingerprints unchanged.
- Content-type rule preserves `keep_render`, drops placement.
- OR scope + `keep_render` → `error.UnsupportedOverrideRedirectRule`, old
  rules preserved (extend the popup atomicity test).
- Reload add/remove toggles the resolved value.

Integration — new `compositor/scripts/test-keep-render.py` (pattern:
`test-background-effect.py` headless isolation + `probe-buffer-retention.py`
harness; `WLR_BACKENDS=headless`, pixman build `-Dvulkan-effects=false`):

- Fixture: reuse `fixtures/buffer-retention-client.c` (callback-driven, CSV
  frames/s) or a derivative with settable app_id; `fixtures/xdg-shell-states.c`
  already reports the SUSPENDED configure bit.
- Cases:
  - no rule → inactive workspace → fps ≈ 0;
  - with rule → inactive workspace → fps ≈ 60 (generous band);
  - minimized → sustained;
  - hot reload add/remove via `aqueousctl session reload`;
  - fully idle session → sustained (proves timer, not frame loop);
  - output soft-disabled → sustained; re-enabled → ~60 not ~120 (no double
    pacing);
  - visible kept window tracks output rate;
  - suspended bit cleared while kept, restored on removal;
  - optional Xwayland and lock arms.
- Stress: `probe-buffer-retention.py` with a `keep_render` rule — pool arm
  `stalled_s == 0`.
- Keep green: `test-fifo.py`, `test-overview.sh`, `test-workspace-cycle.py`,
  existing rule scripts.

## Docs

- `docs/rules.md`: schema row + prose (60 Hz pacing, suspended override, FIFO
  40 Hz cap, root-surface-only, integrated-policy only, GPU/battery warning)
  plus a game example.
- `rules.toml.example`: accepted-fields list + Steam/game-mode example.
- `compositor/README.md`: short cross-reference near the hidden-FIFO section.

## Risks

1. **GPU/battery**: kept clients render continuously by design — opt-in,
   60 Hz cap, no compositor composition (disabled nodes produce no damage).
   Document loudly.
2. **FIFO 40 Hz cap** for hidden FIFO clients (patch 0040): effective rate =
   min(callback rate, FIFO rate).
3. **Buffer retention** under continuous hidden commits — must validate with
   the retention probe.
4. **Double pacing**: avoided by predicate + overview skip; a one-tick overlap
   at lock/unlock transitions is harmless (second send finds no pending
   callback).
5. **wlroots assumptions**: direct `wlr_surface_send_frame_done` bypasses
   scene visibility — safe and precedented; never rely on enabled-offscreen
   nodes.
6. **Schema drift**: missing `collection_schema.zig`/fingerprint updates
   breaks the settings editor or reload ownership.

## Validation

```sh
cd compositor
zig build test
zig build -Dvulkan-effects=false
python3 scripts/test-keep-render.py
python3 scripts/probe-buffer-retention.py   # with keep_render rule
python3 scripts/test-fifo.py --renderer pixman
```

Implementation order: 1–2 (+unit tests) → 3–4 → 5–6 → 7 → docs → integration
script.
