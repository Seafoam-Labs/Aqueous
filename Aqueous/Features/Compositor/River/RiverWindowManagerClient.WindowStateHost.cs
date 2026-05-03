using System;
using System.Collections.Generic;
using System.Diagnostics;
using Aqueous.Features.Layout;
using Aqueous.Features.State;

namespace Aqueous.Features.Compositor.River;

internal sealed unsafe partial class RiverWindowManagerClient
{
    // ------------------------------------------------------------------
    // IWindowStateHost adapter — bridges WindowStateController to the
    // river client's internal window/output dictionaries. Pass B keeps
    // this adapter conservative: every method either consults existing
    // state or asks the manage loop to re-run; it never directly emits
    // Wayland protocol ops. Render-path overrides (visibility, geometry,
    // z-order, borders) are deferred to a follow-up pass.
    //
    // Promoted out of the inline nested-class declaration into its own
    // partial-class file during the Phase 2 readability refactor.
    //
    // Phase 2 / Step 8.B: this is the architectural seam where the
    // strongly-typed proxy value types meet the River-internal IntPtr
    // plumbing. The adapter wraps every IntPtr reaching this layer in
    // a WindowProxy/OutputProxy at the boundary, and unwraps proxies
    // arriving from WindowStateController back to IntPtr for River's
    // internal dictionaries (which use IntPtr because they hold raw
    // wl_proxy* pointers received from the dispatcher).
    // ------------------------------------------------------------------
    private sealed class RiverWindowStateHost : IWindowStateHost
    {
        private readonly RiverWindowManagerClient _c;

        public RiverWindowStateHost(RiverWindowManagerClient c)
        {
            _c = c;
        }

        public WindowStateData? Get(WindowProxy window)
        {
            if (window.IsZero)
            {
                return null;
            }

            if (!_c._windows.ContainsKey(window.Handle))
            {
                return null;
            }

            return _c._windowStates.GetOrAdd(
                window.Handle,
                _ => new WindowStateData { Handle = window });
        }

        public WindowProxy FocusedWindow => new(_c._focusedWindow);

        public OutputProxy FocusedOutput
        {
            get
            {
                var oe = _c.GetFocusedOutputEntry();
                return oe is null ? OutputProxy.Zero : new OutputProxy(oe.Proxy);
            }
        }

        public Rect OutputRect(OutputProxy output)
        {
            if (!output.IsZero && _c._outputs.TryGetValue(output.Handle, out var o))
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

            return _c.ApplyStruts(raw);
        }

        public WindowProxy GetFullscreenWindow(OutputProxy output) =>
            _c._outputFullscreen.TryGetValue(output.Handle, out var w)
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
                _c._outputFullscreen.TryRemove(output.Handle, out _);
            }
            else
            {
                _c._outputFullscreen[output.Handle] = window.Handle;
            }
        }

        public void Focus(WindowProxy window)
        {
            if (!window.IsZero)
            {
                _c.RequestFocus(window.Handle);
            }
        }

        public void FocusNextOnOutput(OutputProxy output) =>
            _c.FocusAnyOtherWindow(_c._focusedWindow);

        public void RequestRender(OutputProxy output) => _c.ScheduleManage();

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

        public void Log(string message) => RiverWindowManagerClient.Log(message);

        public Rect CurrentGeometry(WindowProxy window)
        {
            if (!window.IsZero && _c._windows.TryGetValue(window.Handle, out var w))
            {
                return new Rect(w.X, w.Y, w.W, w.H);
            }

            return new Rect(0, 0, 0, 0);
        }
    }

    internal Rect ApplyStruts(Rect raw)
    {
        var strutsConfig = _layoutConfig?.Struts;
        if (strutsConfig is null)
        {
            return raw;
        }

        if ((strutsConfig.Top | strutsConfig.Bottom | strutsConfig.Left | strutsConfig.Right) == 0)
        {
            return raw;
        }

        var x = raw.X + strutsConfig.Left;
        var y = raw.Y + strutsConfig.Top;
        var w = Math.Max(1, raw.W - strutsConfig.Left - strutsConfig.Right);
        var h = Math.Max(1, raw.H - strutsConfig.Top - strutsConfig.Bottom);
        return new Rect(x, y, w, h);
    }
}
