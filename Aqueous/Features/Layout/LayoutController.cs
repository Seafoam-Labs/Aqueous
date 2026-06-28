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
    /// Engine state is partitioned by <c>(output, workspace)</c> so that the column / band /
    /// monocle ordering a user produces with <see cref="MoveFocused"/> on one workspace survives a
    /// switch to another workspace (whose snapshot would otherwise overwrite the single per-output
    /// slot during the next <see cref="Arrange"/> reconciliation) and is restored intact on return.
    /// </summary>
    private readonly record struct Scope(IntPtr Output, int WorkspaceNumber);

    /// <summary>
    /// Per-scope engine instance.
    /// </summary>
    private readonly Dictionary<Scope, ILayoutEngine> _engineByScope = new();
    /// <summary>
    /// Per-scope engine private state (opaque).
    /// </summary>
    private readonly Dictionary<Scope, object?> _stateByScope = new();
    /// <summary>
    /// Per-scope id of the currently active layout (so we can detect swaps). Keyed by
    /// <c>(output, workspace)</c> so that each workspace remembers its own layout id: switching
    /// workspaces restores that workspace's layout, and <see cref="SetLayoutForWorkspace"/> changes only
    /// the focused workspace. Populated both by explicit per-workspace overrides and lazily by
    /// <see cref="ResolveEngine"/> as the resolved id is cached.
    /// </summary>
    private readonly Dictionary<Scope, string> _idByScope = new();

    /// <summary>
    /// Per-output forced layout id set by <see cref="SetLayoutForOutput"/> ("apply to the whole
    /// monitor"). Ranks below an explicit per-workspace override but above the config-derived
    /// defaults. Kept separate from <see cref="_idByScope"/> so it can be honoured even before any
    /// workspace on the output has been arranged.
    /// </summary>
    private readonly Dictionary<IntPtr, string> _forcedByOutput = new();

    public LayoutController(LayoutRegistry registry, LayoutConfig config)
    {
        _registry = registry ?? throw new ArgumentNullException(nameof(registry));
        _config = config ?? throw new ArgumentNullException(nameof(config));
    }

    public LayoutConfig Config => _config;
    public long Epoch => _epoch;

    /// <summary>
    /// Atomically swap to a new config (epoch bump). Per-scope engine state is kept for workspaces
    /// whose resolved layout id is unchanged — so layout-order memory (e.g. grid/game-mode slot
    /// order) survives a reload — and dropped only for scopes whose resolved id changed, which
    /// recompute from scratch on their next <see cref="Arrange"/>. Floating per-window overrides are
    /// stored outside the controller and survive.
    /// </summary>
    public void ReplaceConfig(LayoutConfig newConfig)
    {
        _config = newConfig ?? throw new ArgumentNullException(nameof(newConfig));
        _epoch++;

        // Layout-order memory across config reloads: rather than dropping everything, keep each
        // workspace's engine + per-scope state (its slot order) when the resolved layout id is
        // unchanged under the new config, and drop only the scopes whose resolved id actually
        // changed so they restart fresh. Explicit per-workspace (_idByScope) and per-output
        // (_forcedByOutput) overrides are preserved so resolution — and thus the kept ordering —
        // stays stable across the reload. Engines recompute geometry every Arrange regardless, so
        // honouring a changed default/per-output id only requires dropping the diverging scopes.
        foreach (var scope in new List<Scope>(_engineByScope.Keys))
        {
            var newId = ResolveLayoutId(new WorkspaceId(scope.Output, scope.WorkspaceNumber));
            if (_engineByScope.TryGetValue(scope, out var engine) && engine.Id == newId)
            {
                continue;
            }

            _engineByScope.Remove(scope);
            _stateByScope.Remove(scope);
            _idByScope.Remove(scope);
        }
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

        // Apply to the whole monitor: drop every (output, *) scope so each workspace picks up the
        // new id with fresh state on its next Arrange/MoveFocused/... call, and remember the forced
        // id so it is honoured even before any workspace on the output has been arranged.
        DropScopesForOutput(output);
        _forcedByOutput[output] = layoutId;
    }

    /// <summary>
    /// Force a single workspace to use a specific layout id, without disturbing the sibling
    /// workspaces on the same output. Falls back to the configured default if the id is not
    /// registered. This is the entry point for per-workspace <c>set_layout_*</c> keybindings.
    /// </summary>
    public void SetLayoutForWorkspace(WorkspaceId workspaceId, string layoutId)
    {
        if (!_registry.Contains(layoutId))
        {
            layoutId = _config.DefaultLayout;
        }

        var scope = new Scope(workspaceId.Output, workspaceId.Number);

        // Layout-order memory: if this workspace is already on the requested layout id, keep its
        // engine + per-scope state (the slot order) intact so a redundant set_layout_* keybinding
        // doesn't reset the ordering. Only drop and restart fresh when the id actually changes.
        if (_idByScope.TryGetValue(scope, out var currentId)
            && string.Equals(currentId, layoutId, StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        // Drop only this workspace's engine/state so it restarts fresh under the new id; sibling
        // workspaces keep their engines and ordering.
        _engineByScope.Remove(scope);
        _stateByScope.Remove(scope);
        _idByScope[scope] = layoutId;
    }

    public void SetLayoutForWorkspace(IntPtr output, int workspaceNumber, string layoutId) =>
        SetLayoutForWorkspace(new WorkspaceId(output, workspaceNumber), layoutId);

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
        // Snapshot the set of outputs we have seen: the union of forced-output ids and the outputs
        // appearing in any (output, workspace) scope (the per-scope map may have multiple entries
        // per output).
        var outputSet = new HashSet<IntPtr>(_forcedByOutput.Keys);
        foreach (var scope in _idByScope.Keys)
        {
            outputSet.Add(scope.Output);
        }
        foreach (var scope in _engineByScope.Keys)
        {
            outputSet.Add(scope.Output);
        }
        var outputs = new List<IntPtr>(outputSet);
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
                PerWorkspace = _config.PerWorkspace,
                PerOutputWorkspace = _config.PerOutputWorkspace,
                Border = _config.Border,
                Blur = _config.Blur,
                Opacity = _config.Opacity,
                WorkspaceTransition = _config.WorkspaceTransition,
                Keybinds = _config.Keybinds,
                ForceSsd = _config.ForceSsd,
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
    /// Resolve which layout a workspace should be using, considering
    /// (in order): 1) an explicit per-workspace override / cached resolution
    /// (<see cref="SetLayoutForWorkspace"/>); 2) a per-output forced id (<see cref="SetLayoutForOutput"/>);
    /// 3) per-workspace config (<c>[[workspace]]</c> in wm.toml); 4) per-output config
    /// (<c>[[output]]</c>); 5) the global default.
    /// </summary>
    public string ResolveLayoutId(WorkspaceId workspaceId, string? outputName = null)
    {
        var scope = new Scope(workspaceId.Output, workspaceId.Number);
        if (_idByScope.TryGetValue(scope, out var scoped) && _registry.Contains(scoped))
        {
            return scoped;
        }

        if (_forcedByOutput.TryGetValue(workspaceId.Output, out var forced) && _registry.Contains(forced))
        {
            return forced;
        }

        var byWorkspace = _config.ResolveLayoutForWorkspace(outputName, workspaceId.Number);
        if (byWorkspace != null && _registry.Contains(byWorkspace))
        {
            return byWorkspace;
        }

        if (outputName != null && _config.PerOutput.TryGetValue(outputName, out var perOutId)
            && _registry.Contains(perOutId))
        {
            return perOutId;
        }

        return _registry.Contains(_config.DefaultLayout) ? _config.DefaultLayout : "tile";
    }

    public string ResolveLayoutId(IntPtr output, string? outputName, int workspaceNumber)
        => ResolveLayoutId(new WorkspaceId(output, workspaceNumber), outputName);

    public LayoutOptions ResolveLayoutOptions(WorkspaceId workspaceId, string? outputName = null)
        => _config.OptionsFor(ResolveLayoutId(workspaceId, outputName));

    /// <summary>
    /// Output-wide resolution that ignores the workspace dimension. Returns an explicit
    /// per-workspace override for any tracked workspace on the output if present, then the forced
    /// per-output id, then per-output config, then the global default. Used by callers that only
    /// have an output handle (e.g. the float-active check).
    /// </summary>
    public string ResolveLayoutId(IntPtr output, string? outputName)
    {
        foreach (var kv in _idByScope)
        {
            if (kv.Key.Output == output && _registry.Contains(kv.Value))
            {
                return kv.Value;
            }
        }

        if (_forcedByOutput.TryGetValue(output, out var forced) && _registry.Contains(forced))
        {
            return forced;
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
        foreach (var k in _idByScope.Keys)
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
            _idByScope.Remove(k);
        }
    }

    /// <summary>
    /// Compute placements for a single output. Caller is responsible for workspace/floating/fullscreen
    /// filtering of <paramref name="visibleWindows"/> and for translating placements into Wayland
    /// requests.
    /// </summary>
    public IReadOnlyList<WindowPlacement> Arrange(
        IntPtr output,
        string? outputName,
        Rect usableArea,
        IReadOnlyList<WindowEntryView> visibleWindows,
        IntPtr focusedWindow,
        int workspaceNumber,
        Rect outputRect = default)
        => Arrange(output, outputName, usableArea, visibleWindows, focusedWindow,
            new WorkspaceId(output, workspaceNumber), outputRect);

    public IReadOnlyList<WindowPlacement> Arrange(
        IntPtr output,
        string? outputName,
        Rect usableArea,
        IReadOnlyList<WindowEntryView> visibleWindows,
        IntPtr focusedWindow,
        WorkspaceId workspaceId,
        Rect outputRect = default)
    {
        var scope = new Scope(workspaceId.Output, workspaceId.Number);
        var engine = ResolveEngine(scope, outputName);
        object? state = _stateByScope.TryGetValue(scope, out var s) ? s : null;
        var opts = _config.OptionsFor(engine.Id) with { OutputRect = outputRect, Border = _config.Border };
        var raw = engine.Arrange(usableArea, visibleWindows, focusedWindow, opts, ref state);
        _stateByScope[scope] = state;

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

    public IntPtr? FocusNeighbor(
        IntPtr output,
        string? outputName,
        IntPtr current,
        FocusDirection dir,
        IReadOnlyList<WindowEntryView> windows,
        int workspaceNumber)
        => FocusNeighbor(output, outputName, current, dir, windows,
            new WorkspaceId(output, workspaceNumber));

    public IntPtr? FocusNeighbor(
        IntPtr output,
        string? outputName,
        IntPtr current,
        FocusDirection dir,
        IReadOnlyList<WindowEntryView> windows,
        WorkspaceId workspaceId)
    {
        var scope = new Scope(workspaceId.Output, workspaceId.Number);
        var engine = ResolveEngine(scope, outputName);
        object? state = _stateByScope.TryGetValue(scope, out var s) ? s : null;
        var r = engine.FocusNeighbor(output, current, dir, windows, ref state);
        _stateByScope[scope] = state;
        return r;
    }

    public bool MoveFocused(
        IntPtr output,
        string? outputName,
        IntPtr focused,
        FocusDirection dir,
        int workspaceNumber)
        => MoveFocused(output, outputName, focused, dir,
            new WorkspaceId(output, workspaceNumber));

    public bool MoveFocused(
        IntPtr output,
        string? outputName,
        IntPtr focused,
        FocusDirection dir,
        WorkspaceId workspaceId)
    {
        var scope = new Scope(workspaceId.Output, workspaceId.Number);
        var engine = ResolveEngine(scope, outputName);
        object? state = _stateByScope.TryGetValue(scope, out var s) ? s : null;
        var r = engine.MoveFocused(output, focused, dir, ref state);
        _stateByScope[scope] = state;
        return r;
    }

    public bool SwapWindows(
        IntPtr output,
        string? outputName,
        IntPtr a,
        IntPtr b,
        int workspaceNumber)
        => SwapWindows(output, outputName, a, b,
            new WorkspaceId(output, workspaceNumber));

    public bool SwapWindows(
        IntPtr output,
        string? outputName,
        IntPtr a,
        IntPtr b,
        WorkspaceId workspaceId)
    {
        var scope = new Scope(workspaceId.Output, workspaceId.Number);
        var engine = ResolveEngine(scope, outputName);
        object? state = _stateByScope.TryGetValue(scope, out var s) ? s : null;
        var r = engine.SwapWindows(output, a, b, ref state);
        _stateByScope[scope] = state;
        return r;
    }

    public void ScrollViewport(
        IntPtr output,
        string? outputName,
        int deltaColumns,
        int workspaceNumber)
        => ScrollViewport(output, outputName, deltaColumns,
            new WorkspaceId(output, workspaceNumber));

    public void ScrollViewport(
        IntPtr output,
        string? outputName,
        int deltaColumns,
        WorkspaceId workspaceId)
    {
        var scope = new Scope(workspaceId.Output, workspaceId.Number);
        var engine = ResolveEngine(scope, outputName);
        object? state = _stateByScope.TryGetValue(scope, out var s) ? s : null;
        engine.ScrollViewport(output, deltaColumns, ref state);
        _stateByScope[scope] = state;
    }

    private ILayoutEngine ResolveEngine(Scope scope, string? outputName)
    {
        var id = ResolveLayoutId(new WorkspaceId(scope.Output, scope.WorkspaceNumber), outputName);
        if (!_engineByScope.TryGetValue(scope, out var engine) || engine.Id != id)
        {
            // Drop only *this* workspace's stale engine/state when its resolved id changes; sibling
            // workspaces on the same output keep their own engines and ordering (the whole point of
            // per-workspace layouts). DropScopesForOutput also clears _idByScope, so do the removal
            // inline for the single scope instead.
            if (engine != null && engine.Id != id)
            {
                _engineByScope.Remove(scope);
                _stateByScope.Remove(scope);
            }
            engine = _registry.Create(id);
            _engineByScope[scope] = engine;
            _stateByScope[scope] = null;
            _idByScope[scope] = id;
        }
        return engine;
    }

    /// <summary>
    /// Called when an output is removed. Drops every scope keyed on <paramref name="output"/>.
    /// </summary>
    public void ForgetOutput(IntPtr output)
    {
        DropScopesForOutput(output);
        _forcedByOutput.Remove(output);
    }
}
