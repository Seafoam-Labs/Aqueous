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

    /// <summary>
    /// Per-output state. Persists across <c>Arrange</c> calls so that <see cref="MoveFocused"/>
    /// can reorder non-anchor windows and have the next <c>Arrange</c> honour the new order via
    /// the round-robin partition into left/right side columns.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <c>NonAnchorOrder</c> is the canonical ordering of every non-anchor window the engine has
    /// seen on this output. <c>Arrange</c> rebuilds it each frame by (a) dropping handles no
    /// longer in <c>visibleWindows</c> or that have become the anchor, and (b) appending newly
    /// seen non-anchor windows in encounter order. Existing positions are preserved.
    /// </para>
    /// <para>
    /// <c>CurrentAnchor</c> is recorded by <c>Arrange</c> after anchor selection so that
    /// <see cref="MoveFocused"/> can refuse to move the anchor without re-running anchor
    /// selection itself.
    /// </para>
    /// </remarks>
    private sealed class State
    {
        public readonly List<IntPtr> NonAnchorOrder = new();
        public IntPtr CurrentAnchor;
    }

    public IReadOnlyList<WindowPlacement> Arrange(
        Rect usableArea,
        IReadOnlyList<WindowEntryView> visibleWindows,
        IntPtr focusedWindow,
        LayoutOptions opts,
        ref object? perOutputState)
    {
        // ---- 0. Hydrate per-output state. Held across frames so MoveFocused can reorder the
        // non-anchor band and have the change observed by the next Arrange. We also use this to
        // expose the active anchor handle to MoveFocused for the anchor guard.
        State state = perOutputState as State ?? new State();
        perOutputState = state;

        // ---- 1. Resolve the sub-engine ids from LayoutOptions.Extra (defaults: grid).
        var remainderId = opts.GetExtra(RemainderKey) ?? DefaultSub;
        var fallbackId  = opts.GetExtra(FallbackKey)  ?? DefaultSub;

        if (string.Equals(remainderId, LayoutId, StringComparison.OrdinalIgnoreCase) ||
            string.Equals(fallbackId,  LayoutId, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                $"game-mode cannot use itself as its remainder/fallback layout " +
                $"(remainder='{remainderId}', fallback='{fallbackId}')");
        }

        // ---- 2. Pick anchor candidate (most-recently-focused IsAnchor window).
        WindowEntryView? anchor = null;
        var bestTick = long.MinValue;
        long bestHandleTieBreak = 0;
        foreach (WindowEntryView w in visibleWindows)
        {
            if (!w.IsAnchor)
            {
                continue;
            }

            // Most-recently-focused wins. Ties (same tick — should not happen in practice
            // since FocusedWindowTracker bumps the counter monotonically) are broken by
            // higher Handle value, deterministic and stable across runs.
            var h = w.Handle.ToInt64();
            if (w.LastFocusTick <= bestTick &&
                (w.LastFocusTick != bestTick || h <= bestHandleTieBreak))
            {
                continue;
            }

            anchor = w;
            bestTick = w.LastFocusTick;
            bestHandleTieBreak = h;
        }

        // ---- 3. No anchor → behave exactly like the fallback layout. The sub-engine gets its
        // own transient state slot so it doesn't clobber our per-output State; ours is preserved
        // (with CurrentAnchor cleared) so a subsequent MoveFocused on an empty band is a no-op
        // rather than a crash.
        if (anchor is null)
        {
            state.CurrentAnchor = IntPtr.Zero;
            SyncNonAnchorOrder(state, visibleWindows, anchorHandle: IntPtr.Zero);

            ILayoutEngine fallback = _registry.Create(fallbackId);
            object? subState = null;
            return fallback.Arrange(usableArea, visibleWindows, focusedWindow, opts, ref subState);
        }

        WindowEntryView a = anchor.Value;
        WindowRule rule = a.Placement!.Rule;
        state.CurrentAnchor = a.Handle;
        SyncNonAnchorOrder(state, visibleWindows, anchorHandle: a.Handle);

        // ---- 4. Resolve anchor rect via the pure geometry kernel.
        // RequestedBuffer{W,H} fall through to "use usableArea" when zero so a window
        // that hasn't surfaced its buffer size yet still produces a sensible centered
        // anchor instead of a 0×0 rect. The geometry kernel additionally clamps.
        var bufW = a.RequestedBufferW > 0 ? a.RequestedBufferW : usableArea.W;
        var bufH = a.RequestedBufferH > 0 ? a.RequestedBufferH : usableArea.H;

        // `ignore_struts = true` resolves the anchor against the raw output rect so the
        // anchored window can reach the very top/left/etc edges of the output, ignoring the
        // exclusion zone reserved for bars/panels. Remainder columns continue to use
        // `usableArea` so other tiles stay inside the struts.
        Rect anchorArea = rule.IgnoreStruts && opts.OutputRect.W > 0 && opts.OutputRect.H > 0
            ? opts.OutputRect
            : usableArea;

        Rect anchorRect = GameModeGeometry.ResolveAnchor(
            anchorArea, bufW, bufH, rule.Size, rule.Anchor, rule.Scale);

        // ---- 5. Compute the two side columns flanking the anchor.
        (Rect leftCol, Rect rightCol) = GameModeGeometry.ResolveSideColumns(usableArea, anchorRect);

        // ---- 6. Partition non-anchor windows across the two columns and hand each
        // non-empty column to a fresh sub-layout instance.
        //
        // Partitioning strategy: stable round-robin over `state.NonAnchorOrder` (even index →
        // left, odd index → right). Using the persisted order — not raw `visibleWindows`
        // order — lets `MoveFocused` swap adjacent entries and have the next Arrange observe
        // the new column assignment. The anchor is never in `NonAnchorOrder`. If one column
        // is `Rect.Empty` (edge-anchored game) all non-anchor windows go to the surviving
        // column, preserving today's degenerate-case behaviour.
        var byHandle = new Dictionary<IntPtr, WindowEntryView>(visibleWindows.Count);
        foreach (WindowEntryView t in visibleWindows)
        {
            byHandle[t.Handle] = t;
        }

        var leftWindows  = new List<WindowEntryView>(visibleWindows.Count);
        var rightWindows = new List<WindowEntryView>(visibleWindows.Count);
        var leftEmpty  = leftCol  == Rect.Empty;
        var rightEmpty = rightCol == Rect.Empty;

        for (var idx = 0; idx < state.NonAnchorOrder.Count; idx++)
        {
            if (!byHandle.TryGetValue(state.NonAnchorOrder[idx], out WindowEntryView w))
            {
                continue; // shouldn't happen — SyncNonAnchorOrder keeps order in sync with visible set.
            }

            switch (leftEmpty)
            {
                case true when rightEmpty:
                    continue;
                case true:
                    rightWindows.Add(w);
                    break;
                default:
                {
                    if (rightEmpty || (idx & 1) == 0)
                    {
                        leftWindows.Add(w);
                    }
                    else
                    {
                        rightWindows.Add(w);
                    }

                    break;
                }
            }
        }

        var result = new List<WindowPlacement>(visibleWindows.Count);

        // Per-column sub-layout state is intentionally NOT persisted across game-mode
        // arrange calls: each column gets its own fresh sub-layout instance with a
        // transient `object? subState = null` slot. Doing otherwise would require a
        // typed wrapper holding (anchor-state, left-state, right-state); the sub-engine
        // recomputes from scratch each frame, same cost grid/tile already pay.
        if (!leftEmpty && leftWindows.Count > 0)
        {
            ILayoutEngine sub = _registry.Create(remainderId);
            object? subState = null;
            IReadOnlyList<WindowPlacement> subPlacements = sub.Arrange(
                leftCol, leftWindows, focusedWindow, opts, ref subState);
            result.AddRange(subPlacements);
        }

        if (!rightEmpty && rightWindows.Count > 0)
        {
            ILayoutEngine sub = _registry.Create(remainderId);
            object? subState = null;
            IReadOnlyList<WindowPlacement> subPlacements = sub.Arrange(
                rightCol, rightWindows, focusedWindow, opts, ref subState);
            result.AddRange(subPlacements);
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

    /// <summary>
    /// Keep <see cref="State.NonAnchorOrder"/> in sync with <paramref name="visibleWindows"/>:
    /// drop handles that are no longer visible <em>or</em> that have become the anchor, then
    /// append newly seen non-anchor windows in encounter order. Existing positions are
    /// preserved so user-issued <see cref="MoveFocused"/> reorders survive across frames.
    /// </summary>
    private static void SyncNonAnchorOrder(
        State state,
        IReadOnlyList<WindowEntryView> visibleWindows,
        IntPtr anchorHandle)
    {
        var live = new HashSet<IntPtr>();
        foreach (WindowEntryView t in visibleWindows)
        {
            var h = t.Handle;
            if (h != anchorHandle)
            {
                live.Add(h);
            }
        }

        state.NonAnchorOrder.RemoveAll(h => !live.Contains(h));

        var known = new HashSet<IntPtr>(state.NonAnchorOrder);
        foreach (WindowEntryView t in visibleWindows)
        {
            var h = t.Handle;
            if (h == anchorHandle)
            {
                continue;
            }

            if (known.Contains(h))
            {
                continue;
            }

            state.NonAnchorOrder.Add(h);
            known.Add(h);
        }
    }

    /// <summary>
    /// Reorder the focused window within the non-anchor band. The anchor is rule-driven and
    /// positionally fixed by <see cref="GameModeGeometry"/>; this method refuses to move it and
    /// never places a non-anchor window into the anchor's slot.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <c>Left</c>/<c>Up</c>/<c>Prev</c> swap with the previous non-anchor entry;
    /// <c>Right</c>/<c>Down</c>/<c>Next</c> with the next. Returns <c>false</c> (no-op, no
    /// mutation) when the focused window is the active anchor, is unknown to the engine, or is
    /// at the edge of the band.
    /// </para>
    /// <para>
    /// Crash-safety: never throws on missing state, empty band, or unknown direction; never
    /// calls into Wayland. State is mutated only when a valid swap occurs.
    /// </para>
    /// </remarks>
    public bool MoveFocused(
        IntPtr output,
        IntPtr focused,
        FocusDirection dir,
        ref object? perOutputState)
    {
        if (perOutputState is not State state)
        {
            return false;
        }

        // Anchor guard: the anchor window is positionally fixed by rules.toml + geometry kernel.
        // Refuse to move it; use rules.toml to change which window is the anchor.
        if (focused == IntPtr.Zero || focused == state.CurrentAnchor)
        {
            return false;
        }

        var i = state.NonAnchorOrder.IndexOf(focused);
        if (i < 0)
        {
            return false;
        }

        var j = dir switch
        {
            FocusDirection.Left or FocusDirection.Up or FocusDirection.Prev   => i - 1,
            FocusDirection.Right or FocusDirection.Down or FocusDirection.Next => i + 1,
            _ => i
        };

        if (j < 0 || j >= state.NonAnchorOrder.Count || j == i)
        {
            return false;
        }

        // By construction NonAnchorOrder never contains the anchor handle, so this swap
        // cannot put a non-anchor window into the anchor's geometric slot.
        (state.NonAnchorOrder[i], state.NonAnchorOrder[j]) =
            (state.NonAnchorOrder[j], state.NonAnchorOrder[i]);
        return true;
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
