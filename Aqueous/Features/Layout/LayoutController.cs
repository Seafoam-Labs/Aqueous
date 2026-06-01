using System;
using System.Collections.Generic;

namespace Aqueous.Features.Layout;

/// <summary>
/// Per-output state machine that calls the resolved <see cref="ILayoutEngine"/> and clamps the
/// engine's output to window min/max hints. Wayland calls are NOT performed here — this class is
/// intentionally pure so it can be unit-tested without a display fixture; the calling
/// <c>RiverWindowManagerClient</c> owns all <c>wl_proxy_marshal_flags</c> emission and consults
/// <see cref="Arrange"/> for what to send.
/// </summary>
public sealed class LayoutController
{
    private readonly LayoutRegistry _registry;
    private LayoutConfig _config;
    private long _epoch;

    /// <summary>
    /// Engine state is partitioned by <c>(output, visibleTags)</c> so that the column / band /
    /// monocle ordering a user produces with <see cref="MoveFocused"/> on tag 1 survives a switch to
    /// tag 2 (whose snapshot would otherwise overwrite the single per-output slot during the next
    /// <see cref="Arrange"/> reconciliation) and is restored intact on the return trip to tag 1.
    /// </summary>
    private readonly record struct Scope(IntPtr Output, uint Tags);

    /// <summary>
    /// Per-scope engine instance.
    /// </summary>
    private readonly Dictionary<Scope, ILayoutEngine> _engineByScope = new();
    /// <summary>
    /// Per-scope engine private state (opaque).
    /// </summary>
    private readonly Dictionary<Scope, object?> _stateByScope = new();
    /// <summary>
    /// Per-output id of the currently active layout (so we can detect swaps). Kept per-output
    /// rather than per-scope: the layout-id selection is an output-wide property — switching tags
    /// does not change which engine the output uses.
    /// </summary>
    private readonly Dictionary<IntPtr, string> _idByOutput = new();

    public LayoutController(LayoutRegistry registry, LayoutConfig config)
    {
        _registry = registry ?? throw new ArgumentNullException(nameof(registry));
        _config = config ?? throw new ArgumentNullException(nameof(config));
    }

    public LayoutConfig Config => _config;
    public long Epoch => _epoch;

    /// <summary>
    /// Atomically swap to a new config. All per-output engine state is dropped on the next <see
    /// cref="Arrange"/> so engines recompute from scratch (epoch bump). Floating per-window overrides
    /// are stored outside the controller and survive.
    /// </summary>
    public void ReplaceConfig(LayoutConfig newConfig)
    {
        _config = newConfig ?? throw new ArgumentNullException(nameof(newConfig));
        _epoch++;
        _engineByScope.Clear();
        _stateByScope.Clear();
        _idByOutput.Clear();
    }

    /// <summary>
    /// Force a specific output to use a specific layout id (e.g. on keybinding). Falls back to the
    /// configured default if the id is not registered.
    /// </summary>
    public void SetLayoutForOutput(IntPtr output, string layoutId)
    {
        if (!_registry.Contains(layoutId))
        {
            layoutId = _config.DefaultLayout;
        }

        // The id is a per-output property; the per-scope engine map is repopulated lazily on the
        // first Arrange/MoveFocused/... call for a given (output, visibleTags) scope. Drop any
        // pre-existing scopes for this output so they pick up the new id with fresh state.
        DropScopesForOutput(output);
        _idByOutput[output] = layoutId;
    }

    /// <summary>
    /// <see cref="LayoutId"/>-Typed overload of <see cref="SetLayoutForOutput(IntPtr, string)"/>.
    /// Plugin-friendly entry point — see <see cref="LayoutId"/> for the normalization rules.
    /// </summary>
    public void SetLayoutForOutput(IntPtr output, LayoutId layoutId) =>
        SetLayoutForOutput(output, layoutId.Value);

    /// <summary>
    /// Switch every currently-tracked output to <paramref name="layoutId"/>. Outputs that haven't been
    /// seen yet will adopt the new id on their next <see cref="ResolveLayoutId"/> via the controller's
    /// default (since the per-output override map now contains the new id for known outputs only).
    /// Unknown layout ids fall back to the global default; engine state is dropped so the layout
    /// starts fresh.
    /// </summary>
    public void SetLayout(string layoutId)
    {
        if (!_registry.Contains(layoutId))
        {
            layoutId = _config.DefaultLayout;
        }
        // Snapshot keys to avoid mutation during iteration. Use _idByOutput as the canonical set
        // of outputs we have seen (the per-scope engine map may have multiple entries per output).
        var outputs = new List<IntPtr>(_idByOutput.Keys);
        if (outputs.Count == 0)
        {
            // No outputs registered yet — use a sentinel so the first ResolveEngine call sees this id. We
            // can't usefully store it without an output; defer to default-config promotion by overwriting the
            // in-memory config's DefaultLayout.
            _config = new LayoutConfig
            {
                DefaultLayout = layoutId,
                Defaults = _config.Defaults,
                Slots = _config.Slots,
                PerLayoutOpts = _config.PerLayoutOpts,
                PerOutput = _config.PerOutput,
                PerOutputSelectors = _config.PerOutputSelectors,
                Border = _config.Border,
                Keybinds = _config.Keybinds,
            };
            _epoch++;
            return;
        }
        foreach (var o in outputs)
        {
            SetLayoutForOutput(o, layoutId);
        }
    }

    /// <summary>
    /// <see cref="LayoutId"/>-Typed overload of <see cref="SetLayout(string)"/>.
    /// </summary>
    public void SetLayout(LayoutId layoutId) => SetLayout(layoutId.Value);

    /// <summary>
    /// Resolve which layout an output should be using, considering (in order): 1) an explicit override
    /// set via <see cref="SetLayoutForOutput"/>; 2) per-output config (<c>[[output]]</c> in wm.toml);
    /// 3) the global default.
    /// </summary>
    public string ResolveLayoutId(IntPtr output, string? outputName)
    {
        if (_idByOutput.TryGetValue(output, out var id) && _registry.Contains(id))
        {
            return id;
        }

        if (outputName != null && _config.PerOutput.TryGetValue(outputName, out var perOutId)
            && _registry.Contains(perOutId))
        {
            return perOutId;
        }

        return _registry.Contains(_config.DefaultLayout) ? _config.DefaultLayout : "tile";
    }

    private void DropScopesForOutput(IntPtr output)
    {
        // Snapshot keys to avoid mutating during iteration.
        List<Scope>? toRemove = null;
        foreach (var k in _engineByScope.Keys)
        {
            if (k.Output == output)
            {
                (toRemove ??= new List<Scope>()).Add(k);
            }
        }
        foreach (var k in _stateByScope.Keys)
        {
            if (k.Output == output)
            {
                (toRemove ??= new List<Scope>()).Add(k);
            }
        }
        if (toRemove == null)
        {
            return;
        }
        foreach (var k in toRemove)
        {
            _engineByScope.Remove(k);
            _stateByScope.Remove(k);
        }
    }

    /// <summary>
    /// Compute placements for a single output. Caller is responsible for tag/floating/fullscreen
    /// filtering of <paramref name="visibleWindows"/> and for translating placements into Wayland
    /// requests.
    /// </summary>
    public IReadOnlyList<WindowPlacement> Arrange(
        IntPtr output,
        string? outputName,
        Rect usableArea,
        IReadOnlyList<WindowEntryView> visibleWindows,
        IntPtr focusedWindow,
        uint visibleTags,
        Rect outputRect = default)
    {
        var scope = new Scope(output, visibleTags);
        var engine = ResolveEngine(scope, outputName);
        var id = engine.Id;

        var opts = _config.OptionsFor(id) with { OutputRect = outputRect, Border = _config.Border };
        object? state = _stateByScope.TryGetValue(scope, out var s) ? s : null;
        var raw = engine.Arrange(usableArea, visibleWindows, focusedWindow, opts, ref state);
        _stateByScope[scope] = state;

        // Apply controller-enforced rules: clamp to min/max hints. Engines are advisory on size — the
        // controller is the source of truth so a buggy plugin layout cannot violate hints.
        var hintsByHandle = new Dictionary<IntPtr, WindowEntryView>(visibleWindows.Count);
        for (int i = 0; i < visibleWindows.Count; i++)
        {
            hintsByHandle[visibleWindows[i].Handle] = visibleWindows[i];
        }

        var clamped = new List<WindowPlacement>(raw.Count);
        for (int i = 0; i < raw.Count; i++)
        {
            var p = raw[i];
            if (hintsByHandle.TryGetValue(p.Handle, out var view))
            {
                var g = LayoutMath.ClampToHints(p.Geometry, view);
                if (g != p.Geometry)
                {
                    p = p with { Geometry = g };
                }
            }
            clamped.Add(p);
        }
        return clamped;
    }

    /// <summary>
    /// Engine-aware directional focus: ask the active engine for the neighbor of <paramref
    /// name="current"/> in <paramref name="dir"/>. Returns <c>null</c> if the engine has no opinion
    /// (the caller should then fall back to its layout-agnostic cycle).
    /// </summary>
    public IntPtr? FocusNeighbor(
        IntPtr output,
        string? outputName,
        IntPtr current,
        FocusDirection dir,
        IReadOnlyList<WindowEntryView> windows,
        uint visibleTags)
    {
        var scope = new Scope(output, visibleTags);
        var engine = ResolveEngine(scope, outputName);
        object? state = _stateByScope.TryGetValue(scope, out var s) ? s : null;
        var r = engine.FocusNeighbor(output, current, dir, windows, ref state);
        _stateByScope[scope] = state;
        return r;
    }

    /// <summary>
    /// Ask the active engine to move the focused window's slot. Returns true if the engine handled it;
    /// the caller should schedule a manage cycle so the new ordering is applied.
    /// </summary>
    public bool MoveFocused(
        IntPtr output,
        string? outputName,
        IntPtr focused,
        FocusDirection dir,
        uint visibleTags)
    {
        var scope = new Scope(output, visibleTags);
        var engine = ResolveEngine(scope, outputName);
        object? state = _stateByScope.TryGetValue(scope, out var s) ? s : null;
        var r = engine.MoveFocused(output, focused, dir, ref state);
        _stateByScope[scope] = state;
        return r;
    }

    /// <summary>
    /// Pan the active engine's viewport by <paramref name="deltaColumns"/> (positive = right, negative
    /// = left). No-op for engines without a viewport concept.
    /// </summary>
    public void ScrollViewport(
        IntPtr output,
        string? outputName,
        int deltaColumns,
        uint visibleTags)
    {
        var scope = new Scope(output, visibleTags);
        var engine = ResolveEngine(scope, outputName);
        object? state = _stateByScope.TryGetValue(scope, out var s) ? s : null;
        engine.ScrollViewport(output, deltaColumns, ref state);
        _stateByScope[scope] = state;
    }

    private ILayoutEngine ResolveEngine(Scope scope, string? outputName)
    {
        var id = ResolveLayoutId(scope.Output, outputName);
        if (!_engineByScope.TryGetValue(scope, out var engine) || engine.Id != id)
        {
            // If the resolved id changed for this output (e.g. SetLayoutForOutput) drop *all* scopes
            // for that output so every visible-tag partition picks up the new engine. Otherwise the
            // user's current tag would adopt the new engine while other tags kept the stale one.
            if (engine != null && engine.Id != id)
            {
                DropScopesForOutput(scope.Output);
            }
            engine = _registry.Create(id);
            _engineByScope[scope] = engine;
            _stateByScope[scope] = null;
            _idByOutput[scope.Output] = id;
        }
        return engine;
    }

    /// <summary>
    /// Called when an output is removed. Drops every scope keyed on <paramref name="output"/>.
    /// </summary>
    public void ForgetOutput(IntPtr output)
    {
        DropScopesForOutput(output);
        _idByOutput.Remove(output);
    }
}
