# Plan — repair silent keyboard-focus loss under load (virtual keyboard + busy client)

## Implementation status (updated)

Implemented Options 1 + 3 plus observability:
- `Seat.resyncKeyboardFocus` (`Seat.zig`): repairs a **cleared** wlroots delivery
  focus against the logical `Seat.focused` surface; gated on unlocked, no
  keyboard grab, keyboard present, and `focused_surface == null` (so grabbed
  popups are never overridden).
- Hooked into `activateKeyboardGroup` (Option 1) and `updateCapabilities`, plus
  the per-seat `WindowManager.renderFinish` loop (Option 3 settle-time).
- IPC seat snapshot now exposes `kb_focus_null`, `kb_focus_match`, `kb_grab`
  (`ShellManager.zig`) so divergence is observable.

Verification:
- No regression: no-mount control 0 failures / 160 rapid probes; pearl
  `tests/native.py` passes the same 11 checks (its line-319 split-pane failure
  is a pre-existing pearl issue, identical with and without this change).
- Stall rate reduced: baseline fixture 4/24 sessions stalled vs 2/24 with the
  fix (same recover-and-retry methodology).

**Residual race (not fully fixed).** The remaining stalls show
`kb_focus_match: true` (delivery focus *correct*) with the seat keyboard
churning — i.e. a keymap/keyboard-lifecycle race while the client is busy with
the GVfs mount, distinct from the focus-divergence class this fix repairs.
wlroots already sends keymap+enter on a new `wl_keyboard` bind
(`seat_client_create_keyboard`), so the residue is a subtle multi-step timing
race (capability drop → GTK rebind → keymap/enter ordering) that needs
client-side `WAYLAND_DEBUG`/GTK tracing to pin down. It is exacerbated by the
headless fixture having no physical keyboard (every `wtype` exit drops the only
keyboard capability); real sessions with a physical keyboard do not churn.
Candidate follow-up: Option 2 (debounce/sticky keyboard capability for
virtual-keyboard sessions) — deferred as higher-risk until the residue is
traced.

## Symptom

Under system load, a focused GTK4 client (Phyto) intermittently stops receiving
keyboard events injected through `virtual-keyboard-unstable-v1` (`wtype`),
shortly after it starts a background GVfs SFTP mount. The compositor's IPC
keeps reporting the window `focused: true`; the client's main loop is alive and
responsive. Delivery stays dead until something forces a fresh
`wl_keyboard.enter` (e.g. IPC `window.activate`).

This is the compositor-side root cause of the "SFTP startup flake" tracked in
pearl's `subprojects/phyto/docs/STABILITY_FIXES_PLAN.md` (Issue 2). The Phyto
mount-cache hardening already landed there does not change the flake rate.

## Confirmed evidence (all reproduced on headless Aqueous fixture)

1. **The mount is required.** Control: 6 parallel sessions × 40 rapid F12
   probes on a plain Phyto window with **no** SFTP connection → **0 failures
   out of 240**. With the background SFTP reconnect, ~1/5 of sessions stall.
2. **Logical focus never changes.** Compositor debug trace during a failing
   run shows a constant `focus=` fingerprint across the stall; no popup, drag,
   Xwayland grab (fixture runs `-no-xwayland`), layer-shell or lock transition.
3. **The client is alive.** strace of a stalled Phyto shows the main loop
   iterating continuously (10 ms preview heartbeat), no blocking gap > 0.2 s.
4. **A fresh enter repairs it.** On 3/3 captured stalls, issuing IPC
   `window.activate` (→ `Seat.focus()` → `keyboardEnterOrLeave`) immediately
   restored probe delivery.
5. **IPC `focused` is blind to the divergence.** `Window.infoSnapshot`
   (`Window.zig` ~L2725) computes `focused` only from logical `Seat.focused`;
   it never inspects `wlr_seat.keyboard_state.focused_surface` or the grab.
   The seat snapshot's `keyboard` field is the active *group*, not the focus
   surface, so it reads null at quiescence and hides the problem.

## Root cause

Two pieces of state are allowed to diverge, and nothing reconciles them
automatically:

- **Logical focus:** `Seat.focused` (a `Focus` union) — what IPC reports.
- **Delivery focus:** `wlr_seat.keyboard_state.focused_surface` (+ the active
  keyboard/keymap and any grab) — where wlroots actually sends keys.

`Seat.focus()` resyncs them only when it is *called* (`Seat.zig` L1019–1026:
if logical focus is unchanged but `focused_surface != target`, re-enter). The
integrated policy only requests focus when focus *changes*
(`wm/Aqueous.zig` L676–693, L800), so once delivery focus is cleared/redirected
while logical focus stays on the window, **no code path re-enters** — keys are
silently dropped until an explicit activate/click.

### Why the mount triggers it

In the headless fixture the **virtual keyboard is the seat's only keyboard**.
Every `wtype` invocation creates a virtual keyboard, sends keys, and exits,
destroying it. Each destroy:

- `KeyboardGroup.unref` (`KeyboardGroup.zig` L143–179): when the active group
  dies and no other group exists, the seat keyboard is left to wlroots'
  `handle_keyboard_destroy` → `wlr_seat_set_keyboard(NULL)`; the focused
  surface is **not** re-entered or cleared.
- `InputDevice.deinit` → `Seat.updateCapabilities` (`Seat.zig` L1321–1339)
  drops `WL_SEAT_CAPABILITY_KEYBOARD`; GTK4 then **destroys its `wl_keyboard`**.
  The next `wtype` re-adds the capability and `activateKeyboardGroup`
  (`Seat.zig` L1301–1307) re-enters **only if
  `keyboard_state.focused_surface` is non-null**:

  ```zig
  seat.wlr_seat.setKeyboard(&group.state);
  if (seat.wlr_seat.keyboard_state.focused_surface) |s| seat.keyboardNotifyEnter(s);
  ```

When the client is idle (control case) this create/destroy + capability churn
resolves cleanly every time. While the GVfs mount keeps Phyto's main loop busy
with D-Bus traffic, GTK processes the capability change / keymap / enter /
key sequence late and out of step; a keymap/enter is missed or applied to a
stale `wl_keyboard`, and `keyboard_state.focused_surface` ends up null/stale
relative to the logical focus. Because `activateKeyboardGroup` keys off
`focused_surface` (not logical focus) and there is no periodic resync, the
stall persists. `window.activate` recovers it precisely because it re-enters
via the logical-focus resync path.

(The exact micro-race — capability churn vs. a mount-induced GTK popup/tooltip
unmap clearing `focused_surface` — should be pinned down with the diagnostic
below before choosing between fix options 1 and 2; both are covered by the
general resync in option 3.)

## Fix design

### Option 1 — re-enter from logical focus when the keyboard changes (targeted)

In `Seat.activateKeyboardGroup` (`Seat.zig` L1301–1307), fall back to the
logical focus surface when wlroots delivery focus is null/stale:

```zig
pub fn activateKeyboardGroup(seat: *Seat, group: *KeyboardGroup) void {
    defer server.shell_manager.dirty();
    seat.wlr_seat.setKeyboard(&group.state);
    const target = seat.wlr_seat.keyboard_state.focused_surface orelse seat.focused.surface();
    if (target) |s| seat.keyboardNotifyEnter(s);
}
```

This repairs the divergence on **every** keyboard activation (each `wtype`),
which is exactly the event that currently fails to re-enter. Low risk: it only
adds an enter when delivery focus was already lost; normal flow is unchanged.

### Option 2 — don't transiently drop the keyboard capability (churn reduction)

Avoid removing `WL_SEAT_CAPABILITY_KEYBOARD` for the brief gap between virtual
keyboards, so GTK4 does not destroy/recreate its `wl_keyboard` on every
`wtype` exit. E.g. debounce capability removal, or keep the capability while a
virtual-keyboard manager global is bound. This removes the client-side
`wl_keyboard` lifecycle churn that the busy client mishandles. Higher risk
(touches capability semantics); prefer only if option 1 alone is insufficient.

### Option 3 — event-driven focus reconciliation (general, recommended companion)

Add a lightweight resync that runs when the seat keyboard or capabilities
change (and optionally once per manage/render settle): if
`seat.focused.surface()` is non-null and differs from
`keyboard_state.focused_surface` (and no keyboard grab is active), call
`keyboardEnterOrLeave(seat.focused.surface())`. This closes the architectural
gap for *all* silent-divergence paths the exploration identified (popup restore
to a non-root parent, drag-grab teardown, capability churn), not just this
trigger. Guard against grabs (`keyboard_state.grab != default_grab`) and lock
state so it never fights an intentional grab.

**Recommendation:** implement Option 1 + Option 3 (Option 1 is the precise
fix; Option 3 prevents the whole class). Consider Option 2 only if reproduction
shows capability churn is the dominant trigger and 1+3 leave residual flakes.

## Diagnostic to pin the exact trigger (before/alongside the fix)

1. Extend the IPC seat snapshot (debug-only or permanent) to report
   `keyboard_state.focused_surface` id and `grab` kind alongside `focused`, so
   divergence is observable. Confirm at stall: `focused` = Phyto,
   `focused_surface` = null/other.
2. Add temporary debug logs in `XdgPopup.restoreFocus`, `Seat.updateCapabilities`,
   `KeyboardGroup.unref`, and `activateKeyboardGroup` printing the surface
   pointers; capture a failing mount run and identify which event clears
   `focused_surface` (popup unmap vs. capability/keyboard removal).
3. Test Option 1 in isolation against the reproduction below; if flakes
   persist, add Option 3 and re-test; use Option 2 only if needed.

## Verification

- **Recovery regression:** the stall must self-heal without `window.activate`.
  Run `/tmp/opencode/sftp_recover_run.py` (8 parallel) — expect 0
  `PROBE_FAIL` (currently ~3/8 with recovery).
- **SFTP loop:** `/tmp/opencode/sftp_size_native.py` ≥ 20 consecutive passes
  under parallel load (currently ~1/5 fail).
- **Control unchanged:** `/tmp/opencode/control_probe.py` stays 0 failures.
- **No grab regressions:** exercise Xwayland keyboard grab (build with
  xwayland), client DnD drag, xdg-popup menus, layer-shell exclusive focus and
  session lock; confirm intentional grabs are not broken by the resync.
- **pearl native suite:** `python3 tests/native.py` (with `-Dtest-hooks=true`)
  and `tests/network_protocols.py` SFTP half.
- Existing compositor input tests: `compositor/aqueous/keyboard_tests.zig`,
  `InputActivityTest.zig`.

## Risks / notes

- Re-entering on keyboard change must not send spurious enters during an active
  grab (Xwayland/drag/IM) — gate on `grab == default_grab` and lock state.
- Option 3 must be cheap (no per-frame allocation) and idempotent; wlroots
  `keyboardNotifyEnter` on an already-entered surface is a no-op-ish but avoid
  redundant keymap churn.
- The NumLock-default change (`f865f64`) and `handleKey` reordering (`912a6ce`)
  are in the same path; verify injected keysyms are unaffected after the fix.
- This fix lives in Aqueous; pearl's mount-cache hardening stays as defense in
  depth. File a companion Aqueous issue referencing this plan and the pearl
  STABILITY_FIXES_PLAN.md Issue 2.