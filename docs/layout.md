# Layout subsystem

This document describes the layout pipeline introduced by Phase 4 of the
readability refactor and how to write a custom layout plugin.

## Architecture

```
Program  →  LayoutRegistry  →  ILayoutFactory  →  ILayoutEngine
                  ↑                                     ↓
            Register(...)                          Arrange(area, windows, …)
                                                        ↓
        LayoutController  ─→  WindowPlacement[] (clamped to hints)
                  ↑
        LayoutConfig (model)        ←─  LayoutConfigLoader (TOML)
```

- `LayoutRegistry` owns the id → factory map. Built-ins are registered
  in its constructor; plugins call `Register(...)` before the first
  `Arrange`.
- `LayoutController` owns per-output engine instances and per-output
  opaque state. It clamps every engine's output to window min/max hints
  via `LayoutMath.ClampToHints` so a buggy plugin cannot violate hints.
- `LayoutConfigLoader` (in `Aqueous/Features/Layout/LayoutConfigLoader.cs`)
  is the hand-rolled TOML subset parser. It is permissive: unknown
  layout ids in `[layout.slots]`, `[[output]]`, and
  `[layout.options.<id>]` survive parsing so plugins can be registered
  after config is loaded.

## Identifiers — `LayoutId`

`LayoutId` is a `readonly record struct` over a normalized lower-case
string. Construct from untrusted input with `LayoutId.From(raw)`; built-in
ids are exposed as `LayoutId.Tile`, `Float`, `Monocle`, `Grid`.

`IsBuiltin` is informational only — resolution always goes through
`LayoutRegistry`, never branches on `IsBuiltin`. This is what keeps
plugin layouts on equal footing with the built-ins.

The recommended id pattern is `^[a-z][a-z0-9._-]*$` (e.g. `myorg.spiral`)
but no syntactic restriction is enforced. Lookups are case-insensitive,
so `MyOrg.Spiral` in TOML still matches a factory registered as
`myorg.spiral`.

## `LayoutMath` — the plugin SDK

`Aqueous.Features.Layout.LayoutMath` is `public static` and contains
helpers used by built-ins and available to plugins:

- `Rect Shrink(Rect r, int margin)` — symmetric inset; floors W/H to 1.
- `IReadOnlyList<(int Offset, int Size)> SplitAxis(int length, int count, int gap)`
  — even split with gaps; last cell absorbs the leftover.
- `Rect ClampToHints(Rect r, in WindowEntryView w)` — apply window
  min/max hints (0 means unbounded, per Wayland convention).

Every helper is total (never throws) so engines can rely on it without
defensive coding.

## Hello-world plugin

```csharp
using System;
using System.Collections.Generic;
using Aqueous.Features.Layout;

namespace MyOrg.Layouts;

public sealed class StripeLayout : ILayoutEngine
{
    public string Id => "myorg.stripe";

    public IReadOnlyList<WindowPlacement> Arrange(
        Rect usableArea,
        IReadOnlyList<WindowEntryView> windows,
        IntPtr focusedWindow,
        LayoutOptions opts,
        ref object? perOutputState)
    {
        var area = LayoutMath.Shrink(usableArea, opts.GapsOuter);
        var rows = LayoutMath.SplitAxis(area.H, windows.Count, opts.GapsInner);
        var result = new List<WindowPlacement>(windows.Count);

        // Plugin-specific knob from [layout.options.myorg.stripe] in wm.toml.
        bool reverse = opts.GetExtraBool("reverse", false);

        for (int i = 0; i < rows.Count; i++)
        {
            int idx = reverse ? rows.Count - 1 - i : i;
            var (dy, h) = rows[i];
            result.Add(new WindowPlacement(
                windows[idx].Handle,
                new Rect(area.X, area.Y + dy, area.W, h),
                ZOrder: 0,
                Visible: true,
                Border: BorderSpec.None));
        }
        return result;
    }
}

public sealed class StripeLayoutFactory : ILayoutFactory
{
    private readonly StripeLayout _shared = new();
    public string Id => "myorg.stripe";
    public string DisplayName => "Stripe";
    public ILayoutEngine Create() => _shared;
}
```

Register it before the first frame:

```csharp
registry.Register(new MyOrg.Layouts.StripeLayoutFactory());
```

Then select it from `wm.toml`:

```toml
[layout]
default = "myorg.stripe"

[layout.options.myorg.stripe]
reverse = "true"

[[output]]
name = "DP-1"
layout = "myorg.stripe"
```

## What's out of scope (today)

- **Dynamic assembly loading** (`AssemblyLoadContext`, MEF, etc.) is not
  implemented. Plugins are linked in-process and call `Register(...)`
  explicitly. The single-process AOT-friendly story keeps the WM
  startup deterministic; a later phase may add an opt-in plugin host.
- **Capability scoping** — plugins run in-process with full trust.
- **A plugin manifest format** — `ILayoutFactory.Id` + `DisplayName`
  is sufficient until at least one real out-of-tree plugin exists.
