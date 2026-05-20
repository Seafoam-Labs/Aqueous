using System;
using System.Diagnostics;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Layout;

namespace Aqueous.Features.State;

/// <summary>
/// Stage 9 PR 9.10 — full literal lift of the nested
/// <c>RiverWindowManagerClient.RiverWindowStateHost</c> class into a
/// top-level <see cref="IWindowStateHost"/> implementation. Behavior is
/// byte-for-byte equivalent to the prior nested class: every method
/// either reads from or writes to the god class's window/output
/// dictionaries via the small set of internal accessors added in PR
/// 9.10. Construction takes a single <see cref="RiverWindowManagerClient"/>
/// reference — the same shape every Stage-9 facade uses, so DI
/// registration and the existing call sites switch to the new type
/// without further plumbing.
///
/// <para>
/// The prior partial <c>RiverWindowManagerClient.WindowStateHost.cs</c>
/// is deleted alongside this lift; the <c>ApplyStruts</c> helper that
/// shared the partial moves into the god class itself (still <c>internal</c>
/// for the LayoutProposer + this host).
/// </para>
/// </summary>
internal sealed class WindowStateHost : IWindowStateHost
{
    private readonly RiverWindowManagerClient _c;

    // Test-only seam for the inform_(un)maximized wire emit. When set
    // to non-null, SetToplevelMaximizedState calls this in lieu of
    // wl_proxy_marshal_flags so unit tests can drive the host with
    // synthetic IntPtr handles without segfaulting in libwayland.
    // Production keeps this null and the real marshal runs.
    internal static Action<IntPtr, uint>? MaximizedMarshalOverride;

    public WindowStateHost(RiverWindowManagerClient c)
    {
        _c = c ?? throw new ArgumentNullException(nameof(c));
    }

    public WindowStateData? Get(WindowProxy window)
    {
        if (window.IsZero)
        {
            return null;
        }

        if (!_c.WindowEntriesContains(window.Handle))
        {
            return null;
        }

        return _c.GetOrAddWindowState(window.Handle, window);
    }

    public WindowProxy FocusedWindow => new(_c.FocusedWindowHandle);

    public OutputProxy FocusedOutput
    {
        get
        {
            var oe = _c.GetFocusedOutputEntryForHost();
            return oe is null ? OutputProxy.Zero : new OutputProxy(oe.Proxy);
        }
    }

    public Rect OutputRect(OutputProxy output)
    {
        if (!output.IsZero && _c.TryGetOutputRect(output.Handle, out var rect))
        {
            return rect;
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

        return _c.ApplyStruts(raw);
    }

    public WindowProxy GetFullscreenWindow(OutputProxy output) =>
        _c.TryGetOutputFullscreen(output.Handle, out var w)
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
            _c.OutputFullscreenRemove(output.Handle);
        }
        else
        {
            _c.OutputFullscreenSet(output.Handle, window.Handle);
        }
    }

    public void Focus(WindowProxy window)
    {
        if (!window.IsZero)
        {
            _c.RequestFocusForHost(window.Handle);
        }
    }

    public void FocusNextOnOutput(OutputProxy output) =>
        _c.FocusAnyOtherWindowForHost(_c.FocusedWindowHandle);

    public void RequestRender(OutputProxy output) => _c.ScheduleManageForHost();

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
            RiverWindowManagerClient.Log($"scratchpad spawn failed: {ex.Message}");
        }
    }

    public void InvalidateFloatRect(WindowProxy window)
    {
        _c.InvalidateFloatRectForHost(window.Handle);
    }

    public void ResetVisibilityLatches(WindowProxy window)
    {
        if (window.Handle == IntPtr.Zero)
        {
            return;
        }

        _c.ResetVisibilityLatchesForHost(window.Handle);
    }

    public bool IsWindowLayoutReady(WindowProxy window)
    {
        if (window.Handle == IntPtr.Zero)
        {
            return false;
        }

        return _c.IsWindowLayoutReadyForHost(window.Handle);
    }

    public void SetToplevelMaximizedState(WindowProxy window, bool maximized)
    {
        if (!_c.SetXdgMaximizedForHost(window.Handle, maximized))
        {
            return;
        }

        // Wire-level: tell River to update the xdg_toplevel state
        // array on its next configure to the client. Without this
        // call strict xdg-shell clients (Chromium, Alacritty) keep
        // seeing state=[activated, maximized] across a restore and
        // either reconcile (Chromium burns one click) or refuse to
        // shrink (Alacritty stays glued at the maximized rect).
        // Opcodes per WlInterfaces.cs river_window_v1 request list:
        //   inform_maximized   = 15
        //   inform_unmaximized = 16
        // Both are zero-arg requests on the river_window_v1 proxy
        // (which is `window.Handle` — same proxy used for opcode 3
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

            // For supervised entries (OnExit set) we run the command
            // *foregrounded* under sh so Process.HasExited / Exited
            // fire when the child terminates. For fire-and-forget
            // entries we keep the existing setsid -f detach semantics
            // — same as the keybind spawn path.
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
                RiverWindowManagerClient.Log($"exec spawn failed: Process.Start returned null for cmd={request.Command}");
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
                        RiverWindowManagerClient.Log($"exec OnExit threw: {ex.Message}");
                    }
                };
            }
        }
        catch (Exception ex)
        {
            RiverWindowManagerClient.Log($"exec spawn failed: {ex.Message}");
        }
    }

    public void ScheduleAfter(TimeSpan delay, Action callback)
    {
        if (callback is null)
        {
            return;
        }

        // Using Timer is the specified fallback in IWindowStateHost, but we must
        // ensure the callback doesn't race with the main Wayland loop or
        // other threads if the callback modifies internal state.
        // StartupExecRunner.Launch (the primary user) is relatively safe as
        // it uses Process.Start and adds to the supervisor list.
        Timer? t = null;
        t = new Timer(_ =>
        {
            try
            {
                callback();
            }
            catch (Exception ex)
            {
                RiverWindowManagerClient.Log($"ScheduleAfter callback threw: {ex.Message}");
            }
            finally
            {
                t?.Dispose();
            }
        }, null, delay, Timeout.InfiniteTimeSpan);
    }

    public void Log(string message) => RiverWindowManagerClient.Log(message);

    public Rect CurrentGeometry(WindowProxy window)
    {
        if (!window.IsZero && _c.TryGetWindowGeometry(window.Handle, out var rect))
        {
            return rect;
        }

        return new Rect(0, 0, 0, 0);
    }

    private static string EscapeForShell(string s) => "'" + s.Replace("'", "'\\''") + "'";
}
