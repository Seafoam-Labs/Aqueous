using System;
using System.Collections.Generic;
using Aqueous.Features.Rules;

namespace Aqueous.Features.Layout.Builtin;

/// <summary>
/// Game-mode layout engine: pins an anchor window (matched by a <c>rules.toml</c> entry)
/// at its requested size and delegates the remainder rect to a configurable sub-layout.
/// <para>
/// Picks the most-recently-focused <c>IsAnchor</c> window on the output, centers (or
/// edge-anchors) it at its requested buffer size via <see cref="GameModeGeometry"/>, and
/// delegates every other window to a configured sub-layout (the "remainder layout",
/// <c>grid</c> by default) running against the single largest surrounding band rectangle.
/// </para>
/// <para>
/// When no anchor candidate is present on the output, the engine is byte-identical to the
/// configured <em>fallback</em> sub-layout — game-mode silently degenerates so it can be set
/// as a per-output default without surprising the user when their game isn't running.
/// </para>
/// <para>
/// Sub-layout resolution: ids come from <see cref="LayoutOptions.Extra"/> keys
/// <c>game_mode.remainder_layout</c> and <c>game_mode.fallback_layout</c>; both default to
/// <c>grid</c>. The engine resolves them through the <see cref="LayoutRegistry"/> passed at
/// construction. Self-recursion (remainder/fallback = <c>game-mode</c>) is rejected with an
/// <see cref="InvalidOperationException"/> on the first <c>Arrange</c> call to fail fast
/// rather than blow the stack at runtime.
/// </para>
/// <para>
/// v1 design choice: the remainder is a single <see cref="Rect"/> (the largest of the four
/// surrounding bands). Filling the other three bands is the v2 L-shape / multi-band work,
/// gated on an <see cref="ILayoutEngine"/> interface change (<c>IReadOnlyList&lt;Rect&gt;</c>
/// instead of a single rect) that is deliberately out of scope here.
/// </para>
/// </summary>
public sealed class GameModeLayout : ILayoutEngine
{
    public const string LayoutId = "game-mode";

    private const string RemainderKey = "game_mode.remainder_layout";
    private const string FallbackKey  = "game_mode.fallback_layout";
    private const string DefaultSub   = "grid";

    private readonly LayoutRegistry _registry;

    public GameModeLayout(LayoutRegistry registry)
    {
        _registry = registry ?? throw new ArgumentNullException(nameof(registry));
    }

    public string Id => LayoutId;

    public IReadOnlyList<WindowPlacement> Arrange(
        Rect usableArea,
        IReadOnlyList<WindowEntryView> visibleWindows,
        IntPtr focusedWindow,
        LayoutOptions opts,
        ref object? perOutputState)
    {
        // ---- 1. Resolve the sub-engine ids from LayoutOptions.Extra (defaults: grid).
        string remainderId = opts.GetExtra(RemainderKey) ?? DefaultSub;
        string fallbackId  = opts.GetExtra(FallbackKey)  ?? DefaultSub;

        if (string.Equals(remainderId, LayoutId, StringComparison.OrdinalIgnoreCase) ||
            string.Equals(fallbackId,  LayoutId, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                $"game-mode cannot use itself as its remainder/fallback layout " +
                $"(remainder='{remainderId}', fallback='{fallbackId}')");
        }

        // ---- 2. Pick anchor candidate (most-recently-focused IsAnchor window).
        WindowEntryView? anchor = null;
        long bestTick = long.MinValue;
        long bestHandleTieBreak = 0;
        for (int i = 0; i < visibleWindows.Count; i++)
        {
            var w = visibleWindows[i];
            if (!w.IsAnchor)
            {
                continue;
            }

            // Most-recently-focused wins. Ties (same tick — should not happen in practice
            // since FocusedWindowTracker bumps the counter monotonically) are broken by
            // higher Handle value, deterministic and stable across runs.
            long h = w.Handle.ToInt64();
            if (w.LastFocusTick > bestTick ||
                (w.LastFocusTick == bestTick && h > bestHandleTieBreak))
            {
                anchor = w;
                bestTick = w.LastFocusTick;
                bestHandleTieBreak = h;
            }
        }

        // ---- 3. No anchor → behave exactly like the fallback layout.
        if (anchor is null)
        {
            var fallback = _registry.Create(fallbackId);
            return fallback.Arrange(usableArea, visibleWindows, focusedWindow, opts, ref perOutputState);
        }

        var a = anchor.Value;
        var rule = a.Placement!.Rule;

        // ---- 4. Resolve anchor rect via the pure geometry kernel.
        // RequestedBuffer{W,H} fall through to "use usableArea" when zero so a window
        // that hasn't surfaced its buffer size yet still produces a sensible centered
        // anchor instead of a 0×0 rect. The geometry kernel additionally clamps.
        int bufW = a.RequestedBufferW > 0 ? a.RequestedBufferW : usableArea.W;
        int bufH = a.RequestedBufferH > 0 ? a.RequestedBufferH : usableArea.H;

        var anchorRect = GameModeGeometry.ResolveAnchor(
            usableArea, bufW, bufH, rule.Size, rule.Anchor, rule.Scale);

        // ---- 5. Compute the remainder rect.
        var remainderRect = GameModeGeometry.ResolveRemainder(usableArea, anchorRect);

        // ---- 6. Hand the non-anchor windows to the remainder layout (or skip when
        // there's nothing to tile / nowhere to put it).
        var others = new List<WindowEntryView>(visibleWindows.Count);
        for (int i = 0; i < visibleWindows.Count; i++)
        {
            if (visibleWindows[i].Handle != a.Handle)
            {
                others.Add(visibleWindows[i]);
            }
        }

        var result = new List<WindowPlacement>(visibleWindows.Count);
        if (others.Count > 0 && remainderRect != Rect.Empty)
        {
            var remainder = _registry.Create(remainderId);
            // Per-output state for the sub-engine is intentionally NOT persisted across
            // game-mode arrange calls in step 1: doing so would require a typed slot
            // (e.g. a wrapper object holding both anchor- and sub-engine state). v1
            // ships with the sub-engine recomputing from scratch each frame; this is
            // the same cost grid/tile already pay (they keep no per-output state).
            object? subState = null;
            var subPlacements = remainder.Arrange(
                remainderRect, others, focusedWindow, opts, ref subState);
            for (int i = 0; i < subPlacements.Count; i++)
            {
                result.Add(subPlacements[i]);
            }
        }

        // ---- 7. Append the anchor placement. ZOrder=1 to render above remainder tiles
        // (defensive — the band remainder cannot overlap the anchor, but a future
        // multi-band remainder might overlap one corner if rounding is loose).
        result.Add(new WindowPlacement(
            Handle: a.Handle,
            Geometry: anchorRect,
            ZOrder: 1,
            Visible: true,
            Border: BorderSpec.None));

        return result;
    }
}

/// <summary>
/// Factory for <see cref="GameModeLayout"/>. Unlike most builtins, game-mode is a stateless
/// dispatcher — its only construction-time dependency is the <see cref="LayoutRegistry"/> it
/// uses to instantiate its remainder / fallback sub-engines. The factory keeps a single
/// shared instance.
/// </summary>
public sealed class GameModeLayoutFactory : ILayoutFactory
{
    private readonly GameModeLayout _shared;

    public GameModeLayoutFactory(LayoutRegistry registry)
    {
        _shared = new GameModeLayout(registry);
    }

    public string Id => GameModeLayout.LayoutId;
    public string DisplayName => "Game Mode";
    public ILayoutEngine Create() => _shared;
}
