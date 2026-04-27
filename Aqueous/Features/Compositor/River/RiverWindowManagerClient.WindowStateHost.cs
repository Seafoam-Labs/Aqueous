using System;
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
    // ------------------------------------------------------------------
    private sealed class RiverWindowStateHost : IWindowStateHost
    {
        private readonly RiverWindowManagerClient _c;

        public RiverWindowStateHost(RiverWindowManagerClient c)
        {
            _c = c;
        }

        public WindowStateData? Get(IntPtr window)
        {
            if (window == IntPtr.Zero)
            {
                return null;
            }

            if (!_c._windows.ContainsKey(window))
            {
                return null;
            }

            return _c._windowStates.GetOrAdd(window, h => new WindowStateData { Handle = h });
        }

        public IntPtr FocusedWindow => _c._focusedWindow;

        public IntPtr FocusedOutput
        {
            get
            {
                var oe = _c.GetFocusedOutputEntry();
                return oe is null ? IntPtr.Zero : oe.Proxy;
            }
        }

        public Rect OutputRect(IntPtr output)
        {
            if (output != IntPtr.Zero && _c._outputs.TryGetValue(output, out var o))
            {
                return new Rect(o.X, o.Y, o.Width, o.Height);
            }

            return new Rect(0, 0, 0, 0);
        }

        public Rect UsableArea(IntPtr output)
        {
            // Pass B simplification: layer-shell exclusive zones and
            // gaps are absorbed by the layout controller; treat the
            // raw output rect as usable for Maximize geometry. A
            // dedicated reservation pass can refine this later.
            return OutputRect(output);
        }

        public IntPtr GetFullscreenWindow(IntPtr output) =>
            _c._outputFullscreen.TryGetValue(output, out var w) ? w : IntPtr.Zero;

        public void SetFullscreenWindow(IntPtr output, IntPtr window)
        {
            if (output == IntPtr.Zero)
            {
                return;
            }

            if (window == IntPtr.Zero)
            {
                _c._outputFullscreen.TryRemove(output, out _);
            }
            else
            {
                _c._outputFullscreen[output] = window;
            }
        }

        public void Focus(IntPtr window)
        {
            if (window != IntPtr.Zero)
            {
                _c.RequestFocus(window);
            }
        }

        public void FocusNextOnOutput(IntPtr output) => _c.FocusAnyOtherWindow(_c._focusedWindow);

        public void RequestRender(IntPtr output) => _c.ScheduleManage();

        public void EmitForeignToplevelFullscreen(IntPtr window, IntPtr output)
        {
            // Pass B: foreign-toplevel sync deferred. See
            // none_of_the_new_keybinds_are_functional.md step 6.
        }

        public void EmitForeignToplevelUnfullscreen(IntPtr window)
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
                var psi = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "/bin/sh",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                };
                psi.ArgumentList.Add("-c");
                psi.ArgumentList.Add($"setsid -f sh -c {EscapeForShell(command)} >/dev/null 2>&1");
                System.Diagnostics.Process.Start(psi);
            }
            catch (Exception ex)
            {
                RiverWindowManagerClient.Log($"scratchpad spawn failed: {ex.Message}");
            }
        }

        public void Log(string message) => RiverWindowManagerClient.Log(message);

        public Rect CurrentGeometry(IntPtr window)
        {
            if (window != IntPtr.Zero && _c._windows.TryGetValue(window, out var w))
            {
                return new Rect(w.X, w.Y, w.W, w.H);
            }

            return new Rect(0, 0, 0, 0);
        }
    }
}
