using System;
using System.Collections.Generic;
using Aqueous.WM.Features.Layout;

namespace Aqueous.WM.Features.State;

/// <summary>
/// Phase B1e — protocol-agnostic surface that <see cref="WindowStateController"/>
/// uses to query and mutate the WM. Implemented by the river client (Pass B);
/// implemented by an in-memory fake in the unit tests so the controller's
/// transition logic can be exercised without a Wayland fixture.
/// </summary>
public interface IWindowStateHost
{
    /// <summary>Look up the state-projection for <paramref name="window"/>, or <c>null</c> if unknown.</summary>
    WindowStateData? Get(IntPtr window);

    /// <summary>Currently focused window on the focused output, or <see cref="IntPtr.Zero"/>.</summary>
    IntPtr FocusedWindow { get; }

    /// <summary>Currently focused output, or <see cref="IntPtr.Zero"/>.</summary>
    IntPtr FocusedOutput { get; }

    /// <summary>Full output rectangle (raw pixels) — used for Fullscreen geometry.</summary>
    Rect OutputRect(IntPtr output);

    /// <summary>Usable area (output minus layer-shell exclusive zones, minus outer gaps) — used for Maximize.</summary>
    Rect UsableArea(IntPtr output);

    /// <summary>Current window-managed fullscreen window for an output, or <see cref="IntPtr.Zero"/>.</summary>
    IntPtr GetFullscreenWindow(IntPtr output);

    /// <summary>Set / clear the per-output fullscreen slot (single-FS rule).</summary>
    void SetFullscreenWindow(IntPtr output, IntPtr window);

    /// <summary>Move keyboard focus to <paramref name="window"/>.</summary>
    void Focus(IntPtr window);

    /// <summary>Focus any other visible window on <paramref name="output"/>; no-op if none.</summary>
    void FocusNextOnOutput(IntPtr output);

    /// <summary>Schedule a manage/render cycle for the given output.</summary>
    void RequestRender(IntPtr output);

    /// <summary>Notify foreign-toplevel listeners that <paramref name="window"/> is entering fullscreen on <paramref name="output"/>.</summary>
    void EmitForeignToplevelFullscreen(IntPtr window, IntPtr output);

    /// <summary>Notify foreign-toplevel listeners that <paramref name="window"/> has left fullscreen.</summary>
    void EmitForeignToplevelUnfullscreen(IntPtr window);

    /// <summary>Spawn a configured scratchpad command (best-effort fork/exec).</summary>
    void Spawn(string command);

    /// <summary>Structured info-level log message.</summary>
    void Log(string message);

    /// <summary>
    /// Returns the WM's idea of the current geometry (last-applied) for
    /// <paramref name="window"/>; used to snapshot pre-FS / pre-Max geometry.
    /// </summary>
    Rect CurrentGeometry(IntPtr window);
}
