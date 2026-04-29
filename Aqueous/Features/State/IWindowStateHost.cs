using System;
using System.Collections.Generic;
using System.Threading;
using Aqueous.Features.Layout;

namespace Aqueous.Features.State;

/// <summary>
/// Phase B1f — extended spawn request used by <c>[[exec]]</c> autostart
/// entries. Carries optional log redirection, per-entry environment
/// overrides, and an exit callback used by the supervisor for restart
/// scheduling. <see cref="IWindowStateHost.Spawn(string)"/> remains the
/// fast path for keybind-driven spawns.
/// </summary>
public sealed record SpawnRequest(
    string Command,
    string? LogPath = null,
    IReadOnlyDictionary<string, string>? Env = null,
    Action<int>? OnExit = null);

/// <summary>
/// Phase B1e — protocol-agnostic surface that <see cref="WindowStateController"/>
/// uses to query and mutate the WM. Implemented by the river client (Pass B);
/// implemented by an in-memory fake in the unit tests so the controller's
/// transition logic can be exercised without a Wayland fixture.
///
/// <para>Phase 2 / Step 8.B: window/output handles are passed as
/// <see cref="WindowProxy"/> / <see cref="OutputProxy"/> value types
/// rather than raw <see cref="IntPtr"/>, so the compiler enforces that
/// a window handle is never accidentally passed where an output is
/// expected.</para>
/// </summary>
public interface IWindowStateHost
{
    /// <summary>Look up the state-projection for <paramref name="window"/>, or <c>null</c> if unknown.</summary>
    WindowStateData? Get(WindowProxy window);

    /// <summary>Currently focused window on the focused output, or <see cref="WindowProxy.Zero"/>.</summary>
    WindowProxy FocusedWindow { get; }

    /// <summary>Currently focused output, or <see cref="OutputProxy.Zero"/>.</summary>
    OutputProxy FocusedOutput { get; }

    /// <summary>Full output rectangle (raw pixels) — used for Fullscreen geometry.</summary>
    Rect OutputRect(OutputProxy output);

    /// <summary>Usable area (output minus layer-shell exclusive zones, minus outer gaps) — used for Maximize.</summary>
    Rect UsableArea(OutputProxy output);

    /// <summary>Current window-managed fullscreen window for an output, or <see cref="WindowProxy.Zero"/>.</summary>
    WindowProxy GetFullscreenWindow(OutputProxy output);

    /// <summary>Set / clear the per-output fullscreen slot (single-FS rule).</summary>
    void SetFullscreenWindow(OutputProxy output, WindowProxy window);

    /// <summary>Move keyboard focus to <paramref name="window"/>.</summary>
    void Focus(WindowProxy window);

    /// <summary>Focus any other visible window on <paramref name="output"/>; no-op if none.</summary>
    void FocusNextOnOutput(OutputProxy output);

    /// <summary>Schedule a manage/render cycle for the given output.</summary>
    void RequestRender(OutputProxy output);

    /// <summary>Notify foreign-toplevel listeners that <paramref name="window"/> is entering fullscreen on <paramref name="output"/>.</summary>
    void EmitForeignToplevelFullscreen(WindowProxy window, OutputProxy output);

    /// <summary>Notify foreign-toplevel listeners that <paramref name="window"/> has left fullscreen.</summary>
    void EmitForeignToplevelUnfullscreen(WindowProxy window);

    /// <summary>Spawn a configured scratchpad command (best-effort fork/exec).</summary>
    void Spawn(string command);

    /// <summary>
    /// Spawn an autostart command with optional log redirection, env
    /// overrides, and an exit callback. The default implementation
    /// degrades to <see cref="Spawn(string)"/> so existing fakes that
    /// don't care about supervision keep compiling unchanged; the river
    /// adapter overrides this with the full <c>setsid</c> + redirect +
    /// env path.
    /// </summary>
    void Spawn(SpawnRequest request)
    {
        if (request is null || string.IsNullOrEmpty(request.Command))
        {
            return;
        }
        Spawn(request.Command);
    }

    /// <summary>
    /// Schedule <paramref name="callback"/> to run on the WM dispatcher
    /// after <paramref name="delay"/>. Used by the autostart supervisor
    /// to back off between restart attempts. The default implementation
    /// uses a <see cref="Timer"/> directly — fakes can override to drive
    /// virtual time in tests.
    /// </summary>
    void ScheduleAfter(TimeSpan delay, Action callback)
    {
        if (callback is null)
        {
            return;
        }
        Timer? t = null;
        t = new Timer(_ =>
        {
            try { callback(); }
            finally { t?.Dispose(); }
        }, null, delay, Timeout.InfiniteTimeSpan);
    }

    /// <summary>Structured info-level log message.</summary>
    void Log(string message);

    /// <summary>
    /// Returns the WM's idea of the current geometry (last-applied) for
    /// <paramref name="window"/>; used to snapshot pre-FS / pre-Max geometry.
    /// </summary>
    Rect CurrentGeometry(WindowProxy window);
}
