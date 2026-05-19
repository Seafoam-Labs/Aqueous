using System;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Focus;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Layout;
using Aqueous.Features.Tags;

namespace Aqueous.Features.Focus;

/// <summary>
/// Stage 4 extraction of <c>RiverWindowManagerClient.Focus.cs</c>.
///
/// <para>
/// Owns the keyboard-focus behaviour previously living on the god
/// class. The <c>_focusedWindow</c> field itself still lives on
/// <see cref="RiverWindowManagerClient"/> because several
/// not-yet-extracted partials read it directly; reads go through
/// <see cref="IFocusServiceCollaborators.FocusedWindow"/> and writes
/// are routed through the same setter so the two stay in sync. The
/// field migrates onto this class in Stage 9 once the god class
/// disappears.
/// </para>
///
/// <para>
/// Pump-thread only.
/// </para>
/// </summary>
internal sealed class FocusService : IFocusService
{
    private readonly IWindowRegistry _windowRegistry;
    private readonly IOutputRegistry _outputRegistry;
    private readonly ISeatRegistry _seatRegistry;
    private readonly IFocusServiceCollaborators _river;

    internal FocusService(
        IWindowRegistry windowRegistry,
        IOutputRegistry outputRegistry,
        ISeatRegistry seatRegistry,
        IFocusServiceCollaborators river)
    {
        _windowRegistry = windowRegistry ?? throw new ArgumentNullException(nameof(windowRegistry));
        _outputRegistry = outputRegistry ?? throw new ArgumentNullException(nameof(outputRegistry));
        _seatRegistry   = seatRegistry   ?? throw new ArgumentNullException(nameof(seatRegistry));
        _river          = river          ?? throw new ArgumentNullException(nameof(river));
    }

    public IntPtr FocusedWindow => _river.FocusedWindow;

    public bool TryGetFocusedAlive(out IntPtr proxy)
    {
        proxy = _river.FocusedWindow;
        if (proxy == IntPtr.Zero)
        {
            return false;
        }

        if (!_windowRegistry.Entries.ContainsKey(proxy))
        {
            _river.FocusedWindow = IntPtr.Zero;
            return false;
        }

        return true;
    }

    public void SetFocusedWindow(IntPtr windowProxy, IntPtr seatProxy)
    {
        var currentFocused = _river.FocusedWindow;
        var pendingWindow = _river.PendingFocusWindow;
        var pendingShellSurface = _river.PendingFocusShellSurface;

        // Skip no-op focus changes. SetFocusedWindow is called from
        // pointer_enter on every mouse crossing; without a correct guard each
        // enter event would issue manage_dirty, creating a manage/render storm
        // that starves other clients' wl_display pings (they die after ~60s).
        if (windowProxy == currentFocused && pendingWindow == windowProxy)
        {
            return; // same focus already pending
        }

        if (windowProxy == currentFocused && pendingWindow == IntPtr.Zero &&
            pendingShellSurface == IntPtr.Zero)
        {
            return; // already focused and applied
        }

        _river.SetPendingFocusWindow(windowProxy, seatProxy);
        _river.FocusedWindow = windowProxy;
        _river.ScheduleManage();
    }

    public void RequestFocus(IntPtr windowProxy)
    {
        // Guard: never schedule focus on a window proxy that isn't tracked.
        // Between the WindowInformation event that originally queued the focus
        // and the manage cycle that drains it, a transient window (splash,
        // self-closing dialog) can already have been destroyed by river. The
        // resulting marshal on a dead object id is a fatal protocol error
        // that aborts river and tears down the entire desktop.
        if (windowProxy == IntPtr.Zero || !_windowRegistry.Entries.ContainsKey(windowProxy))
        {
            _river.Log($"RequestFocus: ignoring stale/unknown window 0x{windowProxy.ToString("x")}");
            return;
        }

        IntPtr seat = ResolveSeat();
        if (seat == IntPtr.Zero)
        {
            return;
        }

        SetFocusedWindow(windowProxy, seat);
    }

    public void ClearFocus()
    {
        IntPtr seat = ResolveSeat();

        _river.SetPendingFocusWindow(IntPtr.Zero, IntPtr.Zero);
        _river.FocusedWindow = IntPtr.Zero;

        if (seat != IntPtr.Zero)
        {
            _river.SendClearFocus(seat);
            _river.Log($"clear_focus on seat 0x{seat.ToString("x")}");
        }

        _river.ScheduleManage();
    }

    public void FocusAnyOtherWindow(IntPtr avoid)
    {
        IntPtr pick = IntPtr.Zero;
        foreach (var k in _windowRegistry.Entries.Keys)
        {
            if (k == avoid)
            {
                continue;
            }

            pick = k;
            break;
        }

        if (pick == IntPtr.Zero)
        {
            foreach (var k in _windowRegistry.Entries.Keys)
            {
                pick = k;
                break;
            }
        }

        if (pick != IntPtr.Zero)
        {
            RequestFocus(pick);
        }
        else
        {
            ClearFocus();
        }
    }

    public void CycleFocus()
    {
        if (_windowRegistry.Entries.Count == 0)
        {
            return;
        }

        var current = _river.FocusedWindow;
        IntPtr next = IntPtr.Zero;
        bool takeNext = false;
        foreach (var k in _windowRegistry.Entries.Keys)
        {
            if (next == IntPtr.Zero)
            {
                next = k; // fallback to first
            }

            if (takeNext)
            {
                next = k;
                takeNext = false;
                break;
            }

            if (k == current)
            {
                takeNext = true;
            }
        }

        if (next != IntPtr.Zero)
        {
            RequestFocus(next);
        }
    }

    public void HandleDirectionalFocus(FocusDirection dir)
    {
        var current = _river.FocusedWindow;
        if (current == IntPtr.Zero || _windowRegistry.Entries.Count == 0)
        {
            CycleFocus();
            return;
        }

        if (!_windowRegistry.Entries.TryGetValue(current, out var fw))
        {
            CycleFocus();
            return;
        }

        IntPtr output = fw.Output;
        string? outputName = _river.ResolveOutputName(output);
        var snapshot = _river.BuildSnapshotFor(output);
        var target = _river.LayoutFocusNeighbor(output, outputName, current, dir, snapshot);
        if (target is { } t && t != IntPtr.Zero && _windowRegistry.Entries.ContainsKey(t))
        {
            _river.ScheduleManage(); // engine may need to recentre viewport
            RequestFocus(t);
            return;
        }

        CycleFocus();
    }

    public void SetFocusedShellSurface(IntPtr shellSurfaceProxy, IntPtr seatProxy)
    {
        _river.SetPendingFocusShellSurface(shellSurfaceProxy, seatProxy);
        // Parity with SetFocusedWindow / ClearFocus: ensure the pending focus
        // is actually flushed on the next manage cycle. Without this, if a
        // layer-shell surface (e.g. the start menu) grabs focus just before a
        // new window maps, the pending focus never ships and the new window
        // can't grab keyboard focus either.
        _river.ScheduleManage();
    }

    public void RepairFocusAfterTagChange()
    {
        var focused = _river.FocusedWindow;
        if (focused != IntPtr.Zero &&
            _windowRegistry.Entries.TryGetValue(focused, out var fw))
        {
            uint mask = TagState.AllTags;
            if (fw.Output != IntPtr.Zero && _outputRegistry.Entries.TryGetValue(fw.Output, out var oe))
            {
                mask = oe.VisibleTags;
            }

            if (TagState.IsVisible(fw.Tags, mask))
            {
                return; // still visible; keep focus.
            }
        }

        IntPtr replacement = IntPtr.Zero;
        IntPtr focusedOutput = IntPtr.Zero;
        uint focusedMask = TagState.AllTags;
        if (focused != IntPtr.Zero &&
            _windowRegistry.Entries.TryGetValue(focused, out var fw2) &&
            fw2.Output != IntPtr.Zero &&
            _outputRegistry.Entries.TryGetValue(fw2.Output, out var oeFromFocus))
        {
            focusedOutput = oeFromFocus.Proxy;
            focusedMask = oeFromFocus.VisibleTags;
        }
        else
        {
            foreach (var kv in _outputRegistry.Entries)
            {
                focusedOutput = kv.Value.Proxy;
                focusedMask = kv.Value.VisibleTags;
                break;
            }
        }

        foreach (var kv in _windowRegistry.Entries)
        {
            var w = kv.Value;
            if (focusedOutput != IntPtr.Zero && w.Output != focusedOutput)
            {
                continue;
            }

            if (!TagState.IsVisible(w.Tags, focusedMask))
            {
                continue;
            }

            replacement = kv.Key;
            break;
        }

        if (replacement == IntPtr.Zero)
        {
            ClearFocus();
        }
        else
        {
            RequestFocus(replacement);
        }
    }

    public void ClearFocusedHandle()
    {
        _river.FocusedWindow = IntPtr.Zero;
    }

    private IntPtr ResolveSeat()
    {
        IntPtr seat = _river.PrimarySeat;
        if (seat != IntPtr.Zero)
        {
            return seat;
        }

        foreach (var k in _seatRegistry.Entries.Keys)
        {
            return k;
        }

        return IntPtr.Zero;
    }
}
