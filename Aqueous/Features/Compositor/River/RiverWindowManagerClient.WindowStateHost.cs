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
            // Pass B simplification: layer-shell exclusive zones and
            // gaps are absorbed by the layout controller; treat the
            // raw output rect as usable for Maximize geometry. A
            // dedicated reservation pass can refine this later.
            return OutputRect(output);
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
            // Pass B: foreign-toplevel sync deferred. See
            // none_of_the_new_keybinds_are_functional.md step 6.
        }

        public void EmitForeignToplevelUnfullscreen(WindowProxy window)
        {
            // Pass B: foreign-toplevel sync deferred.
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

                string inner;
                if (request.OnExit is null)
                {
                    inner = $"setsid -f sh -c {EscapeForShell(request.Command)} {redirect}";
                }
                else
                {
                    // setsid (without -f) keeps us as the parent so we
                    // observe the exit; the child still gets a fresh
                    // session so Ctrl+C in our TTY doesn't kill it.
                    inner = $"setsid sh -c {EscapeForShell(request.Command)} {redirect}";
                }

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
                        try { onExit(proc.ExitCode); }
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
}
