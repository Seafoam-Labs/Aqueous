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
/// v1.5 design choice ("anchor + left column + right column"): the space surrounding the
/// anchor is exposed as the two full-height side bands flanking the anchor (see
/// <see cref="GameModeGeometry.ResolveSideColumns"/>). Non-anchor windows are partitioned
/// across the two columns via stable round-robin over the visible-window order (even
/// index → left, odd → right); if one column is empty (edge-anchored game) all non-anchor
/// windows go to the surviving column. Each non-empty column gets its own fresh sub-layout
/// instance with transient state. Top/bottom strips above and below the anchor are
/// intentionally unused; configurable N and anchor-spans-columns are explicit non-goals.
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

        // ---- 5. Compute the two side columns flanking the anchor.
        var (leftCol, rightCol) = GameModeGeometry.ResolveSideColumns(usableArea, anchorRect);

        // ---- 6. Partition non-anchor windows across the two columns and hand each
        // non-empty column to a fresh sub-layout instance.
        //
        // Partitioning strategy: stable round-robin over the visible-window order
        // (even index → left, odd index → right), with the anchor itself skipped. If
        // one column is Rect.Empty (edge-anchored game), all non-anchor windows go to
        // the surviving column, preserving today's behavior in that degenerate case.
        var leftWindows  = new List<WindowEntryView>(visibleWindows.Count);
        var rightWindows = new List<WindowEntryView>(visibleWindows.Count);
        bool leftEmpty  = leftCol  == Rect.Empty;
        bool rightEmpty = rightCol == Rect.Empty;

        int nonAnchorIndex = 0;
        for (int i = 0; i < visibleWindows.Count; i++)
        {
            var w = visibleWindows[i];
            if (w.Handle == a.Handle)
            {
                continue;
            }

            if (leftEmpty && rightEmpty)
            {
                // No surviving column — nothing to place this frame.
                nonAnchorIndex++;
                continue;
            }
            else if (leftEmpty)
            {
                rightWindows.Add(w);
            }
            else if (rightEmpty)
            {
                leftWindows.Add(w);
            }
            else
            {
                // Both columns alive → round-robin by stable non-anchor index.
                if ((nonAnchorIndex & 1) == 0) leftWindows.Add(w);
                else                            rightWindows.Add(w);
            }
            nonAnchorIndex++;
        }

        var result = new List<WindowPlacement>(visibleWindows.Count);

        // Per-column sub-layout state is intentionally NOT persisted across game-mode
        // arrange calls: each column gets its own fresh sub-layout instance with a
        // transient `object? subState = null` slot. Doing otherwise would require a
        // typed wrapper holding (anchor-state, left-state, right-state); the sub-engine
        // recomputes from scratch each frame, same cost grid/tile already pay.
        if (!leftEmpty && leftWindows.Count > 0)
        {
            var sub = _registry.Create(remainderId);
            object? subState = null;
            var subPlacements = sub.Arrange(
                leftCol, leftWindows, focusedWindow, opts, ref subState);
            for (int i = 0; i < subPlacements.Count; i++)
            {
                result.Add(subPlacements[i]);
            }
        }

        if (!rightEmpty && rightWindows.Count > 0)
        {
            var sub = _registry.Create(remainderId);
            object? subState = null;
            var subPlacements = sub.Arrange(
                rightCol, rightWindows, focusedWindow, opts, ref subState);
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
