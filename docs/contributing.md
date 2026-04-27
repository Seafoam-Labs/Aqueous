# Contributing to Aqueous

This document captures the conventions established during the readability
refactor.


## Naming and layout

- File-scoped namespaces everywhere (`namespace Foo.Bar;`).
- `_camelCase` for private fields, `PascalCase` for everything else.
- Opcode magic numbers belong in a static class with nested groups
  (see `Features/Compositor/River/RiverProtocolOpcodes.cs`).
- Replace large `switch` statements over hand-numbered cases with named
  enum + dictionary-of-delegates dispatch tables when the bodies are
  small (see `Bindings/RiverWindowManagerClient.KeyBindingActionRouter.cs`'s
  `ActionTable`).

## Pointer / handle discipline

The Aqueous WM talks to River over hand-rolled libwayland P/Invoke. Raw
`wl_proxy*` handles are `IntPtr`. Letting `IntPtr` leak into call sites
that semantically hold a window/output/seat caused several mix-up bugs
during the early prototype.

- **Domain handles** — window, output, seat — are passed as
  `WindowProxy`, `OutputProxy`, `SeatProxy` (defined in
  `Features/State/ProxyTypes.cs`) at every API boundary that crosses
  out of the River feature.
- **River-internal plumbing** may continue to use `IntPtr` for the raw
  `wl_proxy*` it receives from the dispatcher; the wrap to a proxy
  happens once at the seam (`RiverWindowStateHost`).
- **`IWindowStateHost`** (in `Features/State/`) is the single
  protocol-agnostic seam. It must take and return only proxy types and
  primitive value types. It must never accept a raw `IntPtr` argument.
- **Allowed `IntPtr` parameters in `Features/Compositor/River/`:**
  - Inside `Connection/` (P/Invoke owners: `WaylandConnection`,
    `EventPump`, `RegistryBinder`).
  - Inside `WaylandInterop.cs` (the P/Invoke surface itself).
  - For non-domain `wl_proxy*` (manager, layer-shell, xkb-bindings,
    chord/key-binding proxies that aren't windows/outputs/seats).
  - For the dispatcher's `data` field (a `GCHandle.ToIntPtr`).
  - Internal River-private dictionaries of `IntPtr → entry` until the
    river feature itself is fully proxied; the seam to the rest of the
    codebase is what matters.

## Logging

- Funnel all River protocol activity through the static
  `RiverWindowManagerClient.Log` action so a host shell can replace the
  sink with a GLib-aware one without recompiling.
- Use `0x{handle.ToInt64():x}` to format pointer-shaped values in log
  messages — it is the convention every existing line follows.

## Testing

- New `IWindowStateHost`-shaped logic should be exercised by the
  in-memory `FakeHost` in `Aqueous.Tests/WindowStateTests.cs` rather
  than by a Wayland fixture.
- Stochastic / state-machine code added under `Features/State/` must
  reach ≥ 1 happy-path test and ≥ 1 edge case before merge.
- All existing tests must remain green after any structural refactor;
  the file-size split passes did not touch a single behavior site, and
  that's the standard.

