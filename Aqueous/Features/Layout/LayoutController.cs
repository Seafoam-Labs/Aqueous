using System;
using System.Collections.Generic;

namespace Aqueous.Features.Layout;

/// <summary>
/// Per-output state machine that calls the resolved <see cref="ILayoutEngine"/>
/// and clamps the engine's output to window min/max hints. Wayland calls
/// are NOT performed here — this class is intentionally pure so it can be
/// unit-tested without a display fixture; the calling
/// <c>RiverWindowManagerClient</c> owns all <c>wl_proxy_marshal_flags</c>
/// emission and consults <see cref="Arrange"/> for what to send.
/// </summary>
public sealed class LayoutController
{
    private readonly LayoutRegistry _registry;
    private LayoutConfig _config;
    private long _epoch;

    /// <summary>per-output engine instance</summary>
    private readonly Dictionary<IntPtr, ILayoutEngine> _engineByOutput = new();
    /// <summary>per-output engine private state (opaque)</summary>
    private readonly Dictionary<IntPtr, object?> _stateByOutput = new();
    /// <summary>per-output id of the currently active layout (so we can detect swaps)</summary>
    private readonly Dictionary<IntPtr, string> _idByOutput = new();

    public LayoutController(LayoutRegistry registry, LayoutConfig config)
    {
        _registry = registry ?? throw new ArgumentNullException(nameof(registry));
        _config = config ?? throw new ArgumentNullException(nameof(config));
    }

    public LayoutConfig Config => _config;
    public long Epoch => _epoch;

    /// <summary>
    /// Atomically swap to a new config. All per-output engine state is
    /// dropped on the next <see cref="Arrange"/> so engines recompute from
    /// scratch (epoch bump). Floating per-window overrides are stored
    /// outside the controller and survive.
    /// </summary>
    public void ReplaceConfig(LayoutConfig newConfig)
    {
        _config = newConfig ?? throw new ArgumentNullException(nameof(newConfig));
        _epoch++;
        _engineByOutput.Clear();
        _stateByOutput.Clear();
        _idByOutput.Clear();
    }

    /// <summary>
    /// Force a specific output to use a specific layout id (e.g. on
    /// keybinding). Falls back to the configured default if the id is not
    /// registered.
    /// </summary>
    public void SetLayoutForOutput(IntPtr output, string layoutId)
    {
        if (!_registry.Contains(layoutId))
        {
            layoutId = _config.DefaultLayout;
        }

        _engineByOutput[output] = _registry.Create(layoutId);
        _stateByOutput[output] = null;
        _idByOutput[output] = layoutId;
    }

    /// <summary>
    /// Switch every currently-tracked output to <paramref name="layoutId"/>.
    /// Outputs that haven't been seen yet will adopt the new id on their
    /// next <see cref="ResolveLayoutId"/> via the controller's default
    /// (since the per-output override map now contains the new id for
    /// known outputs only). Unknown layout ids fall back to the global
    /// default; engine state is dropped so the layout starts fresh.
    /// </summary>
    public void SetLayout(string layoutId)
    {
        if (!_registry.Contains(layoutId))
        {
            layoutId = _config.DefaultLayout;
        }
        // Snapshot keys to avoid mutation during iteration.
        var outputs = new List<IntPtr>(_engineByOutput.Keys);
        if (outputs.Count == 0)
        {
            // No outputs registered yet — use a sentinel so the first
            // ResolveEngine call sees this id. We can't usefully store
            // it without an output; defer to default-config promotion
            // by overwriting the in-memory config's DefaultLayout.
            _config = new LayoutConfig
            {
                DefaultLayout = layoutId,
                Defaults = _config.Defaults,
                Slots = _config.Slots,
                PerLayoutOpts = _config.PerLayoutOpts,
                PerOutput = _config.PerOutput,
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
    /// Resolve which layout an output should be using, considering (in order):
    ///   1) an explicit override set via <see cref="SetLayoutForOutput"/>;
    ///   2) per-output config (<c>[[output]]</c> in wm.toml);
    ///   3) the global default.
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

    /// <summary>
    /// Compute placements for a single output. Caller is responsible for
    /// tag/floating/fullscreen filtering of <paramref name="visibleWindows"/>
    /// and for translating placements into Wayland requests.
    /// </summary>
    public IReadOnlyList<WindowPlacement> Arrange(
        IntPtr output,
        string? outputName,
        Rect usableArea,
        IReadOnlyList<WindowEntryView> visibleWindows,
        IntPtr focusedWindow)
    {
        var engine = ResolveEngine(output, outputName);
        var id = engine.Id;

        var opts = _config.OptionsFor(id);
        object? state = _stateByOutput.TryGetValue(output, out var s) ? s : null;
        var raw = engine.Arrange(usableArea, visibleWindows, focusedWindow, opts, ref state);
        _stateByOutput[output] = state;

        // Apply controller-enforced rules: clamp to min/max hints. Engines
        // are advisory on size — the controller is the source of truth so
        // a buggy plugin layout cannot violate hints.
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
    /// Engine-aware directional focus: ask the active engine for the
    /// neighbor of <paramref name="current"/> in <paramref name="dir"/>.
    /// Returns <c>null</c> if the engine has no opinion (the caller
    /// should then fall back to its layout-agnostic cycle).
    /// </summary>
    public IntPtr? FocusNeighbor(
        IntPtr output,
        string? outputName,
        IntPtr current,
        FocusDirection dir,
        IReadOnlyList<WindowEntryView> windows)
    {
        var engine = ResolveEngine(output, outputName);
        object? state = _stateByOutput.TryGetValue(output, out var s) ? s : null;
        var r = engine.FocusNeighbor(output, current, dir, windows, ref state);
        _stateByOutput[output] = state;
        return r;
    }

    /// <summary>
    /// Ask the active engine to move the focused window's slot. Returns
    /// true if the engine handled it; the caller should schedule a
    /// manage cycle so the new ordering is applied.
    /// </summary>
    public bool MoveFocused(
        IntPtr output,
        string? outputName,
        IntPtr focused,
        FocusDirection dir)
    {
        var engine = ResolveEngine(output, outputName);
        object? state = _stateByOutput.TryGetValue(output, out var s) ? s : null;
        var r = engine.MoveFocused(output, focused, dir, ref state);
        _stateByOutput[output] = state;
        return r;
    }

    /// <summary>
    /// Pan the active engine's viewport by <paramref name="deltaColumns"/>
    /// (positive = right, negative = left). No-op for engines without a
    /// viewport concept.
    /// </summary>
    public void ScrollViewport(
        IntPtr output,
        string? outputName,
        int deltaColumns)
    {
        var engine = ResolveEngine(output, outputName);
        object? state = _stateByOutput.TryGetValue(output, out var s) ? s : null;
        engine.ScrollViewport(output, deltaColumns, ref state);
        _stateByOutput[output] = state;
    }

    private ILayoutEngine ResolveEngine(IntPtr output, string? outputName)
    {
        var id = ResolveLayoutId(output, outputName);
        if (!_engineByOutput.TryGetValue(output, out var engine) || engine.Id != id)
        {
            engine = _registry.Create(id);
            _engineByOutput[output] = engine;
            _stateByOutput[output] = null;
            _idByOutput[output] = id;
        }
        return engine;
    }

    /// <summary>Called when an output is removed.</summary>
    public void ForgetOutput(IntPtr output)
    {
        _engineByOutput.Remove(output);
        _stateByOutput.Remove(output);
        _idByOutput.Remove(output);
    }
}
