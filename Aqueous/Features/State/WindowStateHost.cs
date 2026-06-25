using System;
using Aqueous.Diagnostics;
using System.Diagnostics;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Focus;
using Aqueous.Features.Layout;

namespace Aqueous.Features.State;

/// <summary>
/// Full literal lift of the nested <c>RiverWindowManagerClient.RiverWindowStateHost</c> class into
/// a top-level <see cref="IWindowStateHost"/> implementation.
/// <para>
/// the residual <see cref="RiverWindowManagerClient"/> ctor argument is gone. The host now takes
/// the eight fine-grained singletons that. The accessor partial
/// (<c>RiverWindowManagerClient.WindowStateHostAccessors.cs</c>) is deleted in the same commit.
/// </para>
/// </summary>
internal sealed class WindowStateHost : IWindowStateHost
{
    private readonly IWindowRegistry _windowRegistry;
    private readonly IOutputRegistry _outputRegistry;
    private readonly WindowStateStore _windowStates;
    private readonly OutputFullscreenMap _outputFullscreen;
    private readonly FocusedWindowTracker _focusedWindowTracker;
    private readonly IFocusService _focusService;
    private readonly IManagerRequestSender _managerRequestSender;
    private readonly LayoutController _layoutController;

    // Test-only seam for the inform_(un)maximized wire emit. When set to non-null,
    // SetToplevelMaximizedState calls this in lieu of wl_proxy_marshal_flags so unit tests can drive
    // the host with synthetic IntPtr handles without segfaulting in libwayland. Production keeps this
    // null and the real marshal runs.
    internal static Action<IntPtr, uint>? MaximizedMarshalOverride;

    public WindowStateHost(
        IWindowRegistry windowRegistry,
        IOutputRegistry outputRegistry,
        WindowStateStore windowStates,
        OutputFullscreenMap outputFullscreen,
        FocusedWindowTracker focusedWindowTracker,
        IFocusService focusService,
        IManagerRequestSender managerRequestSender,
        LayoutController layoutController)
    {
        _windowRegistry = windowRegistry ?? throw new ArgumentNullException(nameof(windowRegistry));
        _outputRegistry = outputRegistry ?? throw new ArgumentNullException(nameof(outputRegistry));
        _windowStates = windowStates ?? throw new ArgumentNullException(nameof(windowStates));
        _outputFullscreen = outputFullscreen ?? throw new ArgumentNullException(nameof(outputFullscreen));
        _focusedWindowTracker = focusedWindowTracker ?? throw new ArgumentNullException(nameof(focusedWindowTracker));
        _focusService = focusService ?? throw new ArgumentNullException(nameof(focusService));
        _managerRequestSender = managerRequestSender ?? throw new ArgumentNullException(nameof(managerRequestSender));
        _layoutController = layoutController ?? throw new ArgumentNullException(nameof(layoutController));
    }

    public WindowStateData? Get(WindowProxy window)
    {
        if (window.IsZero)
        {
            return null;
        }

        if (!_windowRegistry.Entries.ContainsKey(window.Handle))
        {
            return null;
        }

        return _windowStates.GetOrAdd(window.Handle, _ => new WindowStateData { Handle = window });
    }

    public WindowProxy FocusedWindow => new(_focusedWindowTracker.Current);

    public OutputProxy FocusedOutput
    {
        get
        {
            var oe = GetFocusedOutputEntry();
            return oe is null ? OutputProxy.Zero : new OutputProxy(oe.Proxy);
        }
    }

    public Rect OutputRect(OutputProxy output)
    {
        if (!output.IsZero && _outputRegistry.Entries.TryGetValue(output.Handle, out var o))
        {
            return new Rect(o.X, o.Y, o.Width, o.Height);
        }

        return new Rect(0, 0, 0, 0);
    }

    public Rect UsableArea(OutputProxy output)
    {
        Rect raw = OutputRect(output);
        if (raw.W <= 0 || raw.H <= 0)
        {
            return raw;
        }

        return StrutsCalculator.Apply(raw, _layoutController.Config?.Struts);
    }

    public WindowProxy GetFullscreenWindow(OutputProxy output) =>
        _outputFullscreen.TryGetValue(output.Handle, out var w)
            ? new WindowProxy(w)
            : WindowProxy.Zero;

    public void SetFullscreenWindow(OutputProxy output, WindowProxy window)
    {
        if (output.IsZero)
        {
            return;
        }

        if (window.IsZero)
        {
            _outputFullscreen.TryRemove(output.Handle, out _);
        }
        else
        {
            _outputFullscreen[output.Handle] = window.Handle;
        }
    }

    public void Focus(WindowProxy window)
    {
        if (!window.IsZero)
        {
            _focusService.RequestFocus(window.Handle);
        }
    }

    public void FocusNextOnOutput(OutputProxy output) =>
        _focusService.FocusAnyOtherWindow(_focusedWindowTracker.Current);

    public void RequestRender(OutputProxy output) => _managerRequestSender.ScheduleManage();

    public void EmitForeignToplevelFullscreen(WindowProxy window, OutputProxy output)
    {
    }

    public void EmitForeignToplevelUnfullscreen(WindowProxy window)
    {
    }

    public void Spawn(string command)
    {
        if (string.IsNullOrEmpty(command))
        {
            return;
        }

        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "/bin/sh",
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            psi.ArgumentList.Add("-c");
            psi.ArgumentList.Add($"setsid -f sh -c {EscapeForShell(command)} >/dev/null 2>&1");
            Process.Start(psi);
        }
        catch (Exception ex)
        {
            RiverLog.Write($"scratchpad spawn failed: {ex.Message}");
        }
    }

    public void InvalidateFloatRect(WindowProxy window)
    {
        if (!_windowRegistry.Entries.TryGetValue(window.Handle, out WindowEntry? entry))
        {
            return;
        }

        entry.HasFloatRect = false;
        entry.LastPosX = int.MinValue;
        entry.LastPosY = int.MinValue;
        entry.LastHintW = int.MinValue;
        entry.LastHintH = int.MinValue;
    }

    public void ResetVisibilityLatches(WindowProxy window)
    {
        if (window.Handle == IntPtr.Zero)
        {
            return;
        }

        // Symmetric counterpart to the hide-pass cache invalidation in LayoutProposer.ProposeForArea:
        // clears HideSent and zeroes the placement/size caches so the next manage cycle re-issues
        // propose_dimensions / set_position and walks the show path for a window that just left the
        // Minimized / tag-hidden / scratchpad-dismissed bucket. No-op if the handle is unknown.
        if (!_windowRegistry.Entries.TryGetValue(window.Handle, out WindowEntry? entry))
        {
            return;
        }

        entry.HideSent = false;
        entry.LastHintW = 0;
        entry.LastHintH = 0;
        entry.LastPosX = int.MinValue;
        entry.LastPosY = int.MinValue;
        entry.LastClipW = 0;
        entry.LastClipH = 0;
    }

    public bool IsWindowLayoutReady(WindowProxy window)
    {
        if (window.Handle == IntPtr.Zero)
        {
            return false;
        }

        // Probe used by WindowStateController.UnminimizeLast to guard the focus_window call against a
        // window that hasn't been re-shown yet. True when the entry is visible and not awaiting a
        // hide-flush. Output assignment happens during the propose pass that follows the focus drain,
        // so gating on Output != 0 here deadlocks the very first manage cycle in nested sessions
        // (entry stays pristine, defer→reschedule loops forever, screen stays black).
        if (!_windowRegistry.Entries.TryGetValue(window.Handle, out WindowEntry? entry))
        {
            return false;
        }

        return entry.Visible && !entry.HideSent;
    }

    public void SetToplevelMaximizedState(WindowProxy window, bool maximized)
    {
        if (!_windowRegistry.Entries.TryGetValue(window.Handle, out WindowEntry? entry))
        {
            return;
        }

        entry.XdgMaximized = maximized;
        // Force the size diff-gate to re-fire on the next manage cycle so the new state array goes out
        // together with a fresh propose_dimensions, even if the size happens to be unchanged across the
        // transition.
        entry.LastHintW = int.MinValue;
        entry.LastHintH = int.MinValue;

        // Wire-level: tell River to update the xdg_toplevel state array on its next configure to the
        // client. Without this call strict xdg-shell clients (Chromium, Alacritty) keep seeing
        // state=[activated, maximized] across a restore and either reconcile (Chromium burns one click)
        // or refuse to shrink (Alacritty stays glued at the maximized rect). Opcodes per WlInterfaces.cs
        // river_window_v1 request list: inform_maximized = 15 inform_unmaximized = 16 Both are zero-arg
        // requests on the river_window_v1 proxy (which is `window.Handle` — same proxy used for opcode 3
        // propose_dimensions in the LayoutProposer).
        if (window.Handle == IntPtr.Zero)
        {
            return;
        }

        uint opcode = maximized ? 15u : 16u;
        var hook = MaximizedMarshalOverride;
        if (hook is not null)
        {
            hook(window.Handle, opcode);
            return;
        }

        WaylandInterop.wl_proxy_marshal_flags(
            window.Handle, opcode, IntPtr.Zero, 0, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
    }

    public void Spawn(SpawnRequest request)
    {
        if (request is null || string.IsNullOrEmpty(request.Command))
        {
            return;
        }

        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "/bin/sh",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = false,
                RedirectStandardError = false,
            };

            // Per-entry env overrides; merged on top of inherited env.
            if (request.Env is { Count: > 0 } envOverrides)
            {
                foreach (var (k, v) in envOverrides)
                {
                    psi.Environment[k] = v;
                }
            }

            // For supervised entries (OnExit set) we run the command *foregrounded* under sh so
            // Process.HasExited / Exited fire when the child terminates. For fire-and-forget entries we keep
            // the existing setsid -f detach semantics — same as the keybind spawn path.
            var redirect = string.IsNullOrEmpty(request.LogPath)
                ? ">/dev/null 2>&1"
                : $">>{EscapeForShell(request.LogPath!)} 2>&1";

            var inner = request.OnExit is null
                ? $"setsid -f sh -c {EscapeForShell(request.Command)} {redirect}"
                : $"setsid sh -c {EscapeForShell(request.Command)} {redirect}";

            psi.ArgumentList.Add("-c");
            psi.ArgumentList.Add(inner);

            var proc = Process.Start(psi);
            if (proc is null)
            {
                RiverLog.Write($"exec spawn failed: Process.Start returned null for cmd={request.Command}");
                return;
            }

            if (request.OnExit is { } onExit)
            {
                proc.EnableRaisingEvents = true;
                proc.Exited += (_, _) =>
                {
                    try
                    {
                        onExit(proc.ExitCode);
                    }
                    catch (Exception ex)
                    {
                        RiverLog.Write($"exec OnExit threw: {ex.Message}");
                    }
                };
            }
        }
        catch (Exception ex)
        {
            RiverLog.Write($"exec spawn failed: {ex.Message}");
        }
    }

    public void ScheduleAfter(TimeSpan delay, Action callback)
    {
        if (callback is null)
        {
            return;
        }

        // Using Timer is the specified fallback in IWindowStateHost, but we must ensure the callback
        // doesn't race with the main Wayland loop or other threads if the callback modifies internal
        // state. StartupExecRunner.Launch (the primary user) is relatively safe as it uses Process.Start
        // and adds to the supervisor list.
        Timer? t = null;
        t = new Timer(_ =>
        {
            try
            {
                callback();
            }
            catch (Exception ex)
            {
                RiverLog.Write($"ScheduleAfter callback threw: {ex.Message}");
            }
            finally
            {
                t?.Dispose();
            }
        }, null, delay, Timeout.InfiniteTimeSpan);
    }

    public void Log(string message) => RiverLog.Write(message);

    public Rect CurrentGeometry(WindowProxy window)
    {
        if (!window.IsZero && _windowRegistry.Entries.TryGetValue(window.Handle, out var w))
        {
            return new Rect(w.X, w.Y, w.W, w.H);
        }

        return new Rect(0, 0, 0, 0);
    }

    /// <summary>
    /// Returns the OutputEntry the keyboard focus currently lives on. Falls back to the first known
    /// output. <c>null</c> if no outputs are tracked yet (e.g. the headless fallback). Lifted from the
    /// deleted <c>WindowStateHostAccessors</c> partial
    /// </summary>
    private OutputEntry? GetFocusedOutputEntry()
    {
        var focused = _focusedWindowTracker.Current;
        if (focused != IntPtr.Zero &&
            _windowRegistry.Entries.TryGetValue(focused, out var fw) &&
            fw.Output != IntPtr.Zero &&
            _outputRegistry.Entries.TryGetValue(fw.Output, out var oeFromFocus))
        {
            return oeFromFocus;
        }

        foreach (var kv in _outputRegistry.Entries)
        {
            return kv.Value;
        }

        return null;
    }

    private static string EscapeForShell(string s) => "'" + s.Replace("'", "'\\''") + "'";
}
