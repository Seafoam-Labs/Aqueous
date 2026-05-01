using System;
using System.Collections.Generic;
using Aqueous.Features.Layout;

namespace Aqueous.Features.State;

/// <summary>
/// Phase B1e — central state machine for the four "window state" operations:
/// fullscreen / maximize / floating / minimize, plus scratchpad summon /
/// dismiss / send. All transitions go through a single object so the
/// invariants (single-FS-per-output, MRU restore stack, scratchpad ↔ tile
/// promotion) live in one place.
///
/// <para>The controller is pure C#: every Wayland call is delegated to an
/// <see cref="IWindowStateHost"/> so this class can be exercised by unit
/// tests with an in-memory host fake.</para>
/// </summary>
public sealed class WindowStateController
{
    private readonly IWindowStateHost _host;
    private readonly ScratchpadRegistry _scratchpads;
    private readonly StateConfig _config;
    private readonly Stack<WindowProxy> _minimizedMru = new();

    public WindowStateController(
        IWindowStateHost host,
        ScratchpadRegistry scratchpads,
        StateConfig? config = null)
    {
        _host = host ?? throw new ArgumentNullException(nameof(host));
        _scratchpads = scratchpads ?? throw new ArgumentNullException(nameof(scratchpads));
        _config = config ?? StateConfig.Default;
    }

    public ScratchpadRegistry Scratchpads => _scratchpads;
    public StateConfig Config => _config;

    /// <summary>Read-only snapshot of the minimized MRU stack (top first), for diagnostics / IPC.</summary>
    public IReadOnlyCollection<WindowProxy> MinimizedMru => _minimizedMru;

    // ------------------------------------------------------------------
    // Fullscreen
    // ------------------------------------------------------------------

    /// <summary>
    /// Toggle <see cref="WindowState.Fullscreen"/>. Enforces the single-FS-
    /// per-output invariant by demoting any prior fullscreen window on the
    /// same output before promoting <paramref name="window"/>.
    /// </summary>
    public bool ToggleFullscreen(WindowProxy window)
    {
        var w = _host.Get(window);
        if (w is null)
        {
            return false;
        }

        var output = !w.PinnedOutput.IsZero ? w.PinnedOutput : _host.FocusedOutput;
        if (output.IsZero)
        {
            return false;
        }

        if (w.State == WindowState.Fullscreen)
        {
            DemoteFromFullscreen(w, output);
            _host.Log($"state ws=0x{window.Handle.ToInt64():x} fullscreen→{w.State} output=0x{output.Handle.ToInt64():x}");
            _host.RequestRender(output);
            return true;
        }

        // Single-FS rule: demote whichever window currently owns the FS slot.
        var prior = _host.GetFullscreenWindow(output);
        if (!prior.IsZero && prior != window)
        {
            var pw = _host.Get(prior);
            if (pw is not null)
            {
                DemoteFromFullscreen(pw, output);
            }
        }

        // Maximize/Floating sub-states stash their own pre-state too — but we
        // record what *we* will restore to, which is the snapshot taken now.
        w.PreFsGeom = _host.CurrentGeometry(window);
        w.PreviousState = w.State;
        w.State = WindowState.Fullscreen;
        w.PinnedOutput = output;
        _host.SetFullscreenWindow(output, window);
        _host.EmitForeignToplevelFullscreen(window, output);
        _host.Log($"state ws=0x{window.Handle.ToInt64():x} {w.PreviousState}→fullscreen output=0x{output.Handle.ToInt64():x}");
        _host.RequestRender(output);
        return true;
    }

    /// <summary>
    /// Honour a foreign-toplevel client request to enter fullscreen.
    /// Identical to <see cref="ToggleFullscreen"/> when not already FS;
    /// no-op otherwise.
    /// </summary>
    public void OnClientRequestedFullscreen(WindowProxy window, OutputProxy? output)
    {
        var w = _host.Get(window);
        if (w is null || w.State == WindowState.Fullscreen)
        {
            return;
        }

        if (output is not null && !output.Value.IsZero)
        {
            w.PinnedOutput = output.Value;
        }

        ToggleFullscreen(window);
    }

    /// <summary>Honour a foreign-toplevel client request to leave fullscreen.</summary>
    public void OnClientRequestedUnfullscreen(WindowProxy window)
    {
        var w = _host.Get(window);
        if (w is null || w.State != WindowState.Fullscreen)
        {
            return;
        }

        ToggleFullscreen(window);
    }

    private void DemoteFromFullscreen(WindowStateData w, OutputProxy output)
    {
        // PreviousState may itself be Maximized/Floating; preserve that.
        w.State = w.PreviousState;
        // PreFsGeom restoration is advisory — the layout engine will
        // recompute Tiled geometry on the next render. Floating/Maximized
        // restore their own remembered rect.
        if (w.State == WindowState.Floating && w.PreFsGeom is { } g)
        {
            w.FloatingGeom = g;
        }

        _host.SetFullscreenWindow(output, WindowProxy.Zero);
        _host.EmitForeignToplevelUnfullscreen(w.Handle);
        w.PreFsGeom = null;
        _host.RequestRender(output);
    }

    // ------------------------------------------------------------------
    // Maximize
    // ------------------------------------------------------------------

    /// <summary>
    /// Toggle <see cref="WindowState.Maximized"/>. Unlike fullscreen, several
    /// windows on the same output may be Maximized simultaneously — the
    /// effect is identical to FS minus the bar-hiding hook because each
    /// covers usable area.
    /// </summary>
    public bool ToggleMaximize(WindowProxy window)
    {
        var w = _host.Get(window);
        if (w is null)
        {
            return false;
        }

        var output = !w.PinnedOutput.IsZero ? w.PinnedOutput : _host.FocusedOutput;
        if (output.IsZero)
        {
            return false;
        }

        if (w.State == WindowState.Maximized)
        {
            w.State = w.PreviousState;
            _host.Log($"state ws=0x{window.Handle.ToInt64():x} maximized→{w.State}");
        }
        else
        {
            // Disallow stacking maximize on top of fullscreen/minimize/scratchpad.
            if (w.State is WindowState.Fullscreen or WindowState.Minimized
                or WindowState.Scratchpad)
            {
                return false;
            }

            w.PreFsGeom = _host.CurrentGeometry(window);
            w.PreviousState = w.State;
            w.State = WindowState.Maximized;
            w.PinnedOutput = output;
            _host.Log($"state ws=0x{window.Handle.ToInt64():x} {w.PreviousState}→maximized");
        }
        _host.RequestRender(output);
        return true;
    }

    // ------------------------------------------------------------------
    // Floating
    // ------------------------------------------------------------------

    /// <summary>
    /// Toggle <see cref="WindowState.Floating"/> ↔ <see cref="WindowState.Tiled"/>.
    /// No-op when the window is currently in an overlay state (FS/Max/Min/Scratch);
    /// callers must demote first.
    /// </summary>
    public bool ToggleFloating(WindowProxy window)
    {
        var w = _host.Get(window);
        if (w is null)
        {
            return false;
        }

        var output = _host.FocusedOutput;

        switch (w.State)
        {
            case WindowState.Floating:
                w.State = WindowState.Tiled;
                _host.Log($"state ws=0x{window.Handle.ToInt64():x} floating→tiled");
                break;
            case WindowState.Tiled:
                w.FloatingGeom ??= ComputeDefaultFloatRect(output);
                w.State = WindowState.Floating;
                _host.Log($"state ws=0x{window.Handle.ToInt64():x} tiled→floating");
                break;
            default:
                return false;
        }
        _host.RequestRender(output);
        return true;
    }

    private Rect ComputeDefaultFloatRect(OutputProxy output)
    {
        var u = _host.UsableArea(output);
        int w = Math.Max(200, (int)(u.W * 0.6));
        int h = Math.Max(150, (int)(u.H * 0.5));
        int x = u.X + (u.W - w) / 2;
        int y = u.Y + (u.H - h) / 2;
        return new Rect(x, y, w, h);
    }

    // ------------------------------------------------------------------
    // Minimize / Unminimize
    // ------------------------------------------------------------------

    /// <summary>
    /// Toggle <see cref="WindowState.Minimized"/>. Minimized windows are
    /// excluded from layout input and from the focus-cycle MRU; the render
    /// path omits the <c>show</c> request so River unmaps the surface.
    /// </summary>
    public bool ToggleMinimize(WindowProxy window)
    {
        var w = _host.Get(window);
        if (w is null)
        {
            return false;
        }

        if (w.State == WindowState.Minimized)
        {
            w.State = w.PreviousState;
            // Drop from MRU (it might not be on top).
            RemoveFromMru(_minimizedMru, window);
            _host.Log($"state ws=0x{window.Handle.ToInt64():x} minimized→{w.State}");
        }
        else
        {
            // Demote any overlay state first so we can correctly restore later.
            if (w.State == WindowState.Fullscreen)
            {
                var fsOut = !w.PinnedOutput.IsZero ? w.PinnedOutput : _host.FocusedOutput;
                if (!fsOut.IsZero)
                {
                    _host.SetFullscreenWindow(fsOut, WindowProxy.Zero);
                }
            }
            w.PreviousState = w.State;
            w.State = WindowState.Minimized;
            _minimizedMru.Push(window);
            if (_host.FocusedWindow == window)
            {
                _host.FocusNextOnOutput(_host.FocusedOutput);
            }

            _host.Log($"state ws=0x{window.Handle.ToInt64():x} {w.PreviousState}→minimized");
        }
        _host.RequestRender(_host.FocusedOutput);
        return true;
    }

    /// <summary>
    /// Pop the most-recently-minimized window and restore it. Returns
    /// <c>false</c> when the MRU stack is empty.
    /// </summary>
    public bool UnminimizeLast()
    {
        while (_minimizedMru.Count > 0)
        {
            var win = _minimizedMru.Pop();
            var w = _host.Get(win);
            if (w is null)
            {
                continue; // window died while minimized
            }

            if (w.State != WindowState.Minimized)
            {
                continue; // already restored elsewhere
            }

            w.State = w.PreviousState;
            _host.Focus(win);
            _host.Log($"state ws=0x{win.Handle.ToInt64():x} minimized→{w.State} (unminimize_last)");
            _host.RequestRender(_host.FocusedOutput);
            return true;
        }
        return false;
    }

    private static void RemoveFromMru(Stack<WindowProxy> stack, WindowProxy handle)
    {
        if (stack.Count == 0)
        {
            return;
        }

        var buf = new WindowProxy[stack.Count];
        int n = 0;
        foreach (var v in stack)
        {
            if (v != handle)
            {
                buf[n++] = v;
            }
        }

        stack.Clear();
        // Stack iterates top→bottom; rebuild bottom→top to preserve order.
        for (int i = n - 1; i >= 0; i--)
        {
            stack.Push(buf[i]);
        }
    }

    // ------------------------------------------------------------------
    // Scratchpad
    // ------------------------------------------------------------------

    /// <summary>
    /// Summon or dismiss the named scratchpad. If the pad is empty and
    /// <see cref="ScratchpadConfig.OnEmpty"/> is <c>"spawn"</c>, the
    /// configured spawn command is executed; the resulting window will
    /// be claimed on its first <c>manage_start</c> by the river client
    /// (Pass B integration).
    /// </summary>
    public bool ToggleScratchpad(string padName)
    {
        if (string.IsNullOrEmpty(padName))
        {
            padName = ScratchpadRegistry.DefaultPad;
        }

        var current = _scratchpads.Get(padName);
        if (current.IsZero)
        {
            // Empty pad — optionally spawn.
            if (string.Equals(_config.Scratchpad.OnEmpty, "spawn", StringComparison.Ordinal)
                && _config.Scratchpad.SpawnCommands.TryGetValue(padName, out var cmd)
                && !string.IsNullOrWhiteSpace(cmd))
            {
                _host.Log($"scratchpad pad={padName} action=spawn cmd={cmd}");
                _host.Spawn(cmd);
            }
            return false;
        }

        var w = _host.Get(current);
        if (w is null)
        {
            _scratchpads.Clear(padName);
            return false;
        }

        var output = _host.FocusedOutput;
        if (w.InScratchpad)
        {
            // Summon — float, centred on focused output.
            w.InScratchpad = false;
            w.Visible = true;
            w.PreviousState = w.State;
            w.State = WindowState.Floating;
            w.PinnedOutput = output;
            w.FloatingGeom = ComputeScratchpadRect(output);
            _host.Focus(current);
            _host.Log($"scratchpad pad={padName} action=summon ws=0x{current.Handle.ToInt64():x}");
        }
        else
        {
            // Dismiss.
            w.PreviousState = WindowState.Floating;
            w.State = WindowState.Scratchpad;
            w.InScratchpad = true;
            w.Visible = false;
            if (_host.FocusedWindow == current)
            {
                _host.FocusNextOnOutput(output);
            }

            _host.Log($"scratchpad pad={padName} action=dismiss ws=0x{current.Handle.ToInt64():x}");
        }
        _host.RequestRender(output);
        return true;
    }

    /// <summary>
    /// Park <paramref name="window"/> in the named scratchpad (creating it
    /// if necessary). Any prior occupant is demoted back to <c>Tiled</c>.
    /// </summary>
    public bool SendToScratchpad(WindowProxy window, string padName)
    {
        if (window.IsZero)
        {
            return false;
        }

        if (string.IsNullOrEmpty(padName))
        {
            padName = ScratchpadRegistry.DefaultPad;
        }

        var w = _host.Get(window);
        if (w is null)
        {
            return false;
        }

        var prior = _scratchpads.Assign(padName, window);
        if (!prior.IsZero && prior != window)
        {
            var pw = _host.Get(prior);
            if (pw is not null)
            {
                pw.InScratchpad = false;
                pw.Visible = true;
                pw.ScratchpadName = null;
                pw.State = WindowState.Tiled;
            }
        }

        w.PreviousState = w.State;
        w.State = WindowState.Scratchpad;
        w.InScratchpad = true;
        w.Visible = false;
        w.ScratchpadName = padName;
        if (_host.FocusedWindow == window)
        {
            _host.FocusNextOnOutput(_host.FocusedOutput);
        }

        _host.Log($"scratchpad pad={padName} action=send ws=0x{window.Handle.ToInt64():x}");
        _host.RequestRender(_host.FocusedOutput);
        return true;
    }

    private Rect ComputeScratchpadRect(OutputProxy output)
    {
        var u = _host.UsableArea(output);
        var sp = _config.Scratchpad;
        int w = Math.Max(200, (int)(u.W * sp.WidthFrac));
        int h = Math.Max(150, (int)(u.H * sp.HeightFrac));
        int x = u.X + (u.W - w) / 2;
        int y = sp.Anchor switch
        {
            "top" => u.Y,
            "bottom" => u.Y + u.H - h,
            _ => u.Y + (u.H - h) / 2,
        };
        return new Rect(x, y, w, h);
    }

    // ------------------------------------------------------------------
    // Lifecycle hooks
    // ------------------------------------------------------------------

    /// <summary>
    /// Called by the host when a managed window is destroyed. Cleans up FS
    /// slots, scratchpad registrations, and the minimized MRU.
    /// </summary>
    public void OnWindowDestroyed(WindowProxy window)
    {
        var w = _host.Get(window);
        if (w is not null)
        {
            if (w.State == WindowState.Fullscreen && !w.PinnedOutput.IsZero)
            {
                _host.SetFullscreenWindow(w.PinnedOutput, WindowProxy.Zero);
            }
        }
        _scratchpads.Forget(window);
        RemoveFromMru(_minimizedMru, window);
    }

    /// <summary>
    /// Called by the host when an output is removed. Migrates pinned
    /// fullscreen / maximized windows off the dead output and demotes
    /// them to their previous state.
    /// </summary>
    public void OnOutputRemoved(OutputProxy output, IEnumerable<WindowStateData> windowsOnOutput)
    {
        foreach (var w in windowsOnOutput)
        {
            if (w.PinnedOutput != output)
            {
                continue;
            }

            if (w.State is WindowState.Fullscreen or WindowState.Maximized)
            {
                w.State = w.PreviousState;
            }

            w.PinnedOutput = _host.FocusedOutput;
        }
    }

    /// <summary>
    /// Called by the host when a window's tag mask changes. Fullscreen
    /// windows demote to their previous state on tag-change (matches dwm /
    /// awesome behaviour).
    /// </summary>
    public void OnTagsChanged(WindowProxy window)
    {
        var w = _host.Get(window);
        if (w is null)
        {
            return;
        }

        if (w.State == WindowState.Fullscreen)
        {
            var output = w.PinnedOutput;
            if (!output.IsZero)
            {
                _host.SetFullscreenWindow(output, WindowProxy.Zero);
            }

            w.State = w.PreviousState;
            _host.EmitForeignToplevelUnfullscreen(window);
            if (!output.IsZero)
            {
                _host.RequestRender(output);
            }
        }
    }
}

// ----------------------------------------------------------------------
// Configuration records (parsed from wm.toml [scratchpad] / [state]).
// ----------------------------------------------------------------------

/// <summary>Phase B1e — <c>[scratchpad]</c> section of <c>wm.toml</c>.</summary>
public sealed record ScratchpadConfig
{
    /// <summary><c>"spawn"</c> or <c>"manual"</c>.</summary>
    public string OnEmpty { get; init; } = "manual";
    public double WidthFrac { get; init; } = 0.6;
    public double HeightFrac { get; init; } = 0.5;
    /// <summary><c>"center"</c>, <c>"top"</c>, or <c>"bottom"</c>.</summary>
    public string Anchor { get; init; } = "center";
    /// <summary>pad-name → shell command, parsed from <c>[scratchpad.spawn]</c>.</summary>
    public IReadOnlyDictionary<string, string> SpawnCommands { get; init; } =
        new Dictionary<string, string>(StringComparer.Ordinal);

    public static ScratchpadConfig Default { get; } = new();
}

/// <summary>Phase B1e — <c>[state]</c> section of <c>wm.toml</c>.</summary>
public sealed record StateConfig
{
    /// <summary>
    /// When <c>true</c>, entering fullscreen also hides layer-shell layers
    /// above <c>bottom</c>. <b>TODO (Pass B / B1f):</b> not yet wired —
    /// requires layer-shell hide/restore plumbing.
    /// </summary>
    public bool FullscreenHidesBar { get; init; } = true;

    /// <summary>When <c>true</c>, Maximize ignores layer-shell exclusive zones.</summary>
    public bool MaximizeFullOutput { get; init; } = false;

    public ScratchpadConfig Scratchpad { get; init; } = ScratchpadConfig.Default;

    public static StateConfig Default { get; } = new();
}
