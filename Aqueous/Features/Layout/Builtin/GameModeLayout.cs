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

        // Persisted fallback sub-engine + its per-output state, populated only when
        // Arrange takes the no-anchor branch. Kept alive across frames so MoveFocused
        // can route into the same engine instance Arrange last used.
        public ILayoutEngine? FallbackEngine;
        public string?        FallbackEngineId;
        public object?        FallbackState;
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

            // Hot-swap guard: if config changed game_mode.fallback_layout since last
            // frame, drop the stale engine + state rather than feed alien state into a
            // different engine. Mirrors LayoutProposer's engine-id invalidation.
            if (state.FallbackEngine is null ||
                !string.Equals(state.FallbackEngineId, fallbackId, StringComparison.OrdinalIgnoreCase))
            {
                state.FallbackEngine   = _registry.Create(fallbackId);
                state.FallbackEngineId = fallbackId;
                state.FallbackState    = null;
            }

            // Permute visibleWindows by NonAnchorOrder so the fallback engine sees windows
            // in the order MoveFocused has put them. NonAnchorOrder is the single source of truth
            // for ordering: the fallback engine itself need not implement MoveFocused (most don't —
            // grid/tile/floating have no swap of their own). Anything not yet in NonAnchorOrder
            // (race between Sync and a brand-new window) is appended in arrival order.
            var byHandleNoAnchor = new Dictionary<IntPtr, WindowEntryView>(visibleWindows.Count);
            foreach (WindowEntryView w in visibleWindows)
            {
                byHandleNoAnchor[w.Handle] = w;
            }
            var ordered = new List<WindowEntryView>(visibleWindows.Count);
            var orderedSeen = new HashSet<IntPtr>();
            foreach (var h in state.NonAnchorOrder)
            {
                if (byHandleNoAnchor.TryGetValue(h, out WindowEntryView w))
                {
                    ordered.Add(w);
                    orderedSeen.Add(h);
                }
            }
            foreach (WindowEntryView w in visibleWindows)
            {
                if (!orderedSeen.Contains(w.Handle))
                {
                    ordered.Add(w);
                }
            }

            // Hand the fallback engine a *fresh, transient* state each frame so it renders exactly
            // the order we computed from NonAnchorOrder. A stateful sub-engine (e.g. grid) persists
            // its own slot order and reconciles by keeping existing entries, so reusing its state
            // would make it ignore our permutation. Because NonAnchorOrder is authoritative and is
            // preserved across frames (and across anchor/no-anchor transitions), the sub-engine's
            // own ordering memory is redundant here — FallbackState is just per-frame scratch.
            object? scratch = null;
            return state.FallbackEngine.Arrange(
                usableArea, ordered, focusedWindow, opts, ref scratch);
        }

        WindowEntryView a = anchor.Value;
        WindowRule rule = a.Placement!.Rule;
        state.CurrentAnchor = a.Handle;
        SyncNonAnchorOrder(state, visibleWindows, anchorHandle: a.Handle);

        // Anchor mode owns layout now; release fallback engine state so a later
        // degenerate frame starts cleanly (and doesn't pin a sub-engine instance in memory).
        state.FallbackEngine   = null;
        state.FallbackEngineId = null;
        state.FallbackState    = null;

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
            Border: opts.Border));

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
        // In degenerate mode (CurrentAnchor == Zero), a real window handle can never match
        // IntPtr.Zero, so this guard is a no-op there — which is what we want: the same
        // NonAnchorOrder swap drives both anchor and no-anchor layout paths, since Arrange's
        // no-anchor branch now permutes visibleWindows by NonAnchorOrder before delegating.
        if (focused == IntPtr.Zero || focused == state.CurrentAnchor)
        {
            return false;
        }

        // No-anchor branch: apply the grid swap math directly to NonAnchorOrder, the single source
        // of truth for band ordering. Delegating to the fallback sub-engine's own state would only
        // mutate FallbackState (transient scratch that is wiped whenever an anchor appears or the
        // fallback id changes), so the move would be lost across mode transitions. Mirrors
        // GridLayout.MoveFocused: Left/Right = idx ± 1, Up/Down = idx ± cols (cols = ceil(sqrt(n))),
        // with the short-last-row Down clamp. Arrange's no-anchor branch then permutes
        // visibleWindows by NonAnchorOrder, so the grid renders the new order without needing its
        // own swap.
        if (state.CurrentAnchor == IntPtr.Zero)
        {
            var idx = state.NonAnchorOrder.IndexOf(focused);
            if (idx < 0 || state.NonAnchorOrder.Count < 2)
            {
                return false;
            }

            int n = state.NonAnchorOrder.Count;
            int cols = (int)Math.Ceiling(Math.Sqrt(n));

            int target = dir switch
            {
                FocusDirection.Left or FocusDirection.Prev => idx - 1,
                FocusDirection.Right or FocusDirection.Next => idx + 1,
                FocusDirection.Up => idx - cols,
                FocusDirection.Down => idx + cols,
                _ => idx,
            };

            // Down into the empty cell of a short last row clamps to the last existing window.
            if (dir == FocusDirection.Down && target >= n && idx < n - 1)
            {
                target = n - 1;
            }

            if (target < 0 || target >= n || target == idx)
            {
                return false;
            }

            (state.NonAnchorOrder[idx], state.NonAnchorOrder[target]) =
                (state.NonAnchorOrder[target], state.NonAnchorOrder[idx]);
            return true;
        }

        var i = state.NonAnchorOrder.IndexOf(focused);
        if (i < 0)
        {
            return false;
        }

        var count = state.NonAnchorOrder.Count;

        // Anchor branch: non-anchor windows are split round-robin across two side columns (even
        // idx → left, odd idx → right). Up/Down move within a column (the entry two positions
        // away, idx ± 2); Left/Right cross to the other column (the adjacent entry, idx ± 1).
        var j = dir switch
        {
            FocusDirection.Up or FocusDirection.Prev => i - 2,
            FocusDirection.Down or FocusDirection.Next => i + 2,
            FocusDirection.Left => i - 1,
            FocusDirection.Right => i + 1,
            _ => i,
        };

        if (j < 0 || j >= count || j == i)
        {
            return false;
        }

        // By construction NonAnchorOrder never contains the anchor handle, so this swap
        // cannot put a non-anchor window into the anchor's geometric slot.
        (state.NonAnchorOrder[i], state.NonAnchorOrder[j]) =
            (state.NonAnchorOrder[j], state.NonAnchorOrder[i]);
        return true;
    }

    /// <summary>
    /// Move focus across the non-anchor band so <c>focus_*</c> tracks the same geometry as
    /// <see cref="MoveFocused"/>: the no-anchor branch steps by grid math (<c>±1</c> horizontal,
    /// <c>±cols</c> vertical); the anchor branch steps within a side column (<c>±2</c>) or crosses
    /// columns (<c>±1</c>). The anchor itself is never returned, and the result is live-checked
    /// against the current snapshot. Returns <c>null</c> (controller falls back to its default
    /// cycle) on any edge / missing-state case.
    /// </summary>
    public IntPtr? FocusNeighbor(
        IntPtr output,
        IntPtr current,
        FocusDirection dir,
        IReadOnlyList<WindowEntryView> windows,
        ref object? perOutputState)
    {
        if (perOutputState is not State state)
        {
            return null;
        }

        // No-anchor branch: step through NonAnchorOrder by the same grid math MoveFocused uses
        // (±1 horizontal, ±cols vertical, short-last-row Down clamp) so focus_* tracks the band's
        // canonical order rather than the transient FallbackState.
        if (state.CurrentAnchor == IntPtr.Zero)
        {
            var idx = state.NonAnchorOrder.IndexOf(current);
            if (idx < 0)
            {
                return null;
            }

            int n = state.NonAnchorOrder.Count;
            int cols = (int)Math.Ceiling(Math.Sqrt(n));

            int target = dir switch
            {
                FocusDirection.Left or FocusDirection.Prev => idx - 1,
                FocusDirection.Right or FocusDirection.Next => idx + 1,
                FocusDirection.Up => idx - cols,
                FocusDirection.Down => idx + cols,
                _ => idx,
            };

            if (dir == FocusDirection.Down && target >= n && idx < n - 1)
            {
                target = n - 1;
            }

            if (target < 0 || target >= n || target == idx)
            {
                return null;
            }

            var hh = state.NonAnchorOrder[target];
            var liveNoAnchor = new HashSet<IntPtr>();
            foreach (WindowEntryView w in windows)
            {
                liveNoAnchor.Add(w.Handle);
            }
            return liveNoAnchor.Contains(hh) ? hh : (IntPtr?)null;
        }

        var i = state.NonAnchorOrder.IndexOf(current);
        if (i < 0)
        {
            return null;
        }

        var count = state.NonAnchorOrder.Count;

        // Anchor branch: ± 2 within a side column, ± 1 to cross columns (mirrors MoveFocused).
        var j = dir switch
        {
            FocusDirection.Up or FocusDirection.Prev => i - 2,
            FocusDirection.Down or FocusDirection.Next => i + 2,
            FocusDirection.Left => i - 1,
            FocusDirection.Right => i + 1,
            _ => i,
        };

        if (j < 0 || j >= count || j == i)
        {
            return null;
        }

        var h = state.NonAnchorOrder[j];

        var live = new HashSet<IntPtr>();
        foreach (WindowEntryView w in windows)
        {
            live.Add(w.Handle);
        }
        return live.Contains(h) ? h : (IntPtr?)null;
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
