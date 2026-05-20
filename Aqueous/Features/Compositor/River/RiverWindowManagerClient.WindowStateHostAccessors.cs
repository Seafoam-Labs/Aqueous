using System;
using Aqueous.Features.Layout;
using Aqueous.Features.State;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Stage 9 PR 9.10 — accessor partial that exposes the small set of
/// private fields and helpers the new top-level
/// <see cref="Aqueous.Features.State.WindowStateHost"/> reads/writes.
/// Replaces the deleted partial <c>RiverWindowManagerClient.WindowStateHost.cs</c>
/// (which previously held the nested <c>RiverWindowStateHost</c> class
/// inline) and folds in the <c>GetFocusedOutputEntry</c> helper from
/// the deleted <c>Tags/RiverWindowManagerClient.Tags.cs</c> partial.
///
/// <para>
/// Behavior is byte-for-byte equivalent to the prior nested-class
/// implementation: every accessor here is the direct field read/write
/// or one-line forward the nested class used to perform inline. The
/// accessors retire when Stage 9 final (PR 9.12) deletes the god
/// class entirely.
/// </para>
/// </summary>
internal sealed unsafe partial class RiverWindowManagerClient
{
    // --- Window registry / state -------------------------------------
    internal bool WindowEntriesContains(IntPtr handle) =>
        _windowRegistry.Entries.ContainsKey(handle);

    internal WindowStateData GetOrAddWindowState(IntPtr handle, WindowProxy proxy) =>
        _windowStates.GetOrAdd(handle, _ => new WindowStateData { Handle = proxy });

    internal bool TryGetWindowGeometry(IntPtr handle, out Rect rect)
    {
        if (_windowRegistry.Entries.TryGetValue(handle, out var w))
        {
            rect = new Rect(w.X, w.Y, w.W, w.H);
            return true;
        }

        rect = default;
        return false;
    }

    internal void InvalidateFloatRectForHost(IntPtr handle)
    {
        if (!_windowRegistry.Entries.TryGetValue(handle, out WindowEntry? windowHandle))
        {
            return;
        }

        windowHandle.HasFloatRect = false;
        windowHandle.LastPosX = int.MinValue;
        windowHandle.LastPosY = int.MinValue;
        windowHandle.LastHintW = int.MinValue;
        windowHandle.LastHintH = int.MinValue;
    }

    /// <summary>
    /// Symmetric counterpart to the hide-pass cache invalidation in
    /// <c>RiverWindowManagerClient.LayoutProposer.ProposeForArea</c>:
    /// clears <c>HideSent</c> and zeroes the placement/size caches so
    /// the next manage cycle re-issues <c>propose_dimensions</c> /
    /// <c>set_position</c> and walks the show path for a window that
    /// just left the Minimized / tag-hidden / scratchpad-dismissed
    /// bucket. No-op if the handle is unknown (window already
    /// destroyed).
    /// </summary>
    internal void ResetVisibilityLatchesForHost(IntPtr handle)
    {
        if (!_windowRegistry.Entries.TryGetValue(handle, out WindowEntry? entry))
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

    /// <summary>
    /// Probe used by <c>WindowStateController.UnminimizeLast</c> to
    /// guard the <c>focus_window</c> call against a window that
    /// hasn't been re-shown yet. Returns true when the entry is in a
    /// layout bucket (non-zero output, tag-visible, not awaiting a
    /// hide-flush).
    /// </summary>
    internal bool IsWindowLayoutReadyForHost(IntPtr handle)
    {
        if (!_windowRegistry.Entries.TryGetValue(handle, out WindowEntry? entry))
        {
            return false;
        }

        return entry.Output != IntPtr.Zero && entry.TagVisible && !entry.HideSent;
    }

    /// <summary>
    /// Sets the XdgMaximized flag + force-invalidates LastHintW/H on
    /// the matching window entry. Returns true iff the entry exists
    /// (the caller then proceeds to emit the wire-level marshal).
    /// </summary>
    internal bool SetXdgMaximizedForHost(IntPtr handle, bool maximized)
    {
        if (!_windowRegistry.Entries.TryGetValue(handle, out WindowEntry? entry))
        {
            return false;
        }

        entry.XdgMaximized = maximized;
        // Force the size diff-gate to re-fire on the next manage
        // cycle so the new state array goes out together with a
        // fresh propose_dimensions, even if the size happens to be
        // unchanged across the transition.
        entry.LastHintW = int.MinValue;
        entry.LastHintH = int.MinValue;
        return true;
    }

    // --- Output registry / fullscreen map ----------------------------
    internal bool TryGetOutputRect(IntPtr handle, out Rect rect)
    {
        if (_outputRegistry.Entries.TryGetValue(handle, out var o))
        {
            rect = new Rect(o.X, o.Y, o.Width, o.Height);
            return true;
        }

        rect = default;
        return false;
    }

    internal bool TryGetOutputFullscreen(IntPtr output, out IntPtr window) =>
        _outputFullscreen.TryGetValue(output, out window);

    internal void OutputFullscreenSet(IntPtr output, IntPtr window) =>
        _outputFullscreen[output] = window;

    internal void OutputFullscreenRemove(IntPtr output) =>
        _outputFullscreen.TryRemove(output, out _);

    // --- Focus + manage forwards (private helpers in other partials) -
    internal IntPtr FocusedWindowHandle => _focusedWindow;

    internal void RequestFocusForHost(IntPtr windowProxy) => RequestFocus(windowProxy);

    internal void FocusAnyOtherWindowForHost(IntPtr avoid) => FocusAnyOtherWindow(avoid);

    internal void ScheduleManageForHost() => ScheduleManage();

    // --- ApplyStruts (was the bottom of the deleted WindowStateHost partial)
    /// <summary>
    /// Subtracts configured struts (top/bottom/left/right) from a raw
    /// output rect, clamping width/height to ≥1. Consumed by
    /// <see cref="Aqueous.Features.State.WindowStateHost.UsableArea"/>
    /// and by <c>ManagerEventHandler</c>'s start-up output snapshot path.
    /// </summary>
    internal Rect ApplyStruts(Rect raw) =>
        StrutsCalculator.Apply(raw, _layoutConfig?.Struts);

    // --- Tags partial fold (was RiverWindowManagerClient.Tags.cs) ----
    /// <summary>
    /// Returns the OutputEntry the keyboard focus currently lives on.
    /// Falls back to the first known output. <c>null</c> if no outputs
    /// are tracked yet (e.g. the headless fallback).
    ///
    /// Originally lived in the Tags partial; folded here in PR 9.10
    /// because the only remaining caller is <see cref="Aqueous.Features.State.WindowStateHost"/>.
    /// </summary>
    internal OutputEntry? GetFocusedOutputEntryForHost()
    {
        if (_focusedWindow != IntPtr.Zero &&
            _windowRegistry.Entries.TryGetValue(_focusedWindow, out var fw) &&
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
}
