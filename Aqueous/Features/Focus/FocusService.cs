using System;
using Aqueous.Features.Compositor.River;
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
    // PR 9.12 §2.13 Step 1: cut over off RiverWindowManagerClient.
    // The focused/pending-focus/primary-seat state lives on three DI
    // singletons (FocusedWindowTracker / PendingFocusStore /
    // PrimarySeatTracker); SendClearFocus is now an inlined Wayland
    // marshal local to this service.
    private readonly FocusedWindowTracker _focusedWindow;
    private readonly PendingFocusStore _pendingFocus;
    private readonly PrimarySeatTracker _primarySeat;
    private readonly IManagerRequestSender _managerRequestSender;
    private readonly ILayoutProposer _layoutProposer;
    internal FocusService(
        IWindowRegistry windowRegistry,
        IOutputRegistry outputRegistry,
        ISeatRegistry seatRegistry,
        FocusedWindowTracker focusedWindow,
        PendingFocusStore pendingFocus,
        PrimarySeatTracker primarySeat,
        IManagerRequestSender managerRequestSender,
        ILayoutProposer layoutProposer)
    {
        _windowRegistry        = windowRegistry        ?? throw new ArgumentNullException(nameof(windowRegistry));
        _outputRegistry        = outputRegistry        ?? throw new ArgumentNullException(nameof(outputRegistry));
        _seatRegistry          = seatRegistry          ?? throw new ArgumentNullException(nameof(seatRegistry));
        _focusedWindow         = focusedWindow         ?? throw new ArgumentNullException(nameof(focusedWindow));
        _pendingFocus          = pendingFocus          ?? throw new ArgumentNullException(nameof(pendingFocus));
        _primarySeat           = primarySeat           ?? throw new ArgumentNullException(nameof(primarySeat));
        _managerRequestSender  = managerRequestSender  ?? throw new ArgumentNullException(nameof(managerRequestSender));
        _layoutProposer        = layoutProposer        ?? throw new ArgumentNullException(nameof(layoutProposer));
    }

    public IntPtr FocusedWindow => _focusedWindow.Current;

    public bool TryGetFocusedAlive(out IntPtr proxy)
    {
        proxy = _focusedWindow.Current;
        if (proxy == IntPtr.Zero)
        {
            return false;
        }

        if (!_windowRegistry.Entries.ContainsKey(proxy))
        {
            _focusedWindow.Current = IntPtr.Zero;
            return false;
        }

        return true;
    }

    public void SetFocusedWindow(IntPtr windowProxy, IntPtr seatProxy)
    {
        var currentFocused = _focusedWindow.Current;
        var pendingWindow = _pendingFocus.Window;
        var pendingShellSurface = _pendingFocus.ShellSurface;

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

        _pendingFocus.SetWindow(windowProxy, seatProxy);
        _focusedWindow.Current = windowProxy;
        _managerRequestSender.ScheduleManage();
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
            RiverWindowManagerClient.Log($"RequestFocus: ignoring stale/unknown window 0x{windowProxy.ToString("x")}");
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

        _pendingFocus.SetWindow(IntPtr.Zero, IntPtr.Zero);
        _focusedWindow.Current = IntPtr.Zero;

        if (seat != IntPtr.Zero)
        {
            // PR 9.12 §2.13 Step 1: inlined from RiverWindowManagerClient.SendClearFocus.
            // river_seat_v1::clear_focus is opcode 3 with no arguments.
            WaylandInterop.wl_proxy_marshal_flags(seat, 3, IntPtr.Zero, 0, 0,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            RiverWindowManagerClient.Log($"clear_focus on seat 0x{seat.ToString("x")}");
        }

        _managerRequestSender.ScheduleManage();
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

        var current = _focusedWindow.Current;
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
        var current = _focusedWindow.Current;
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
        string? outputName = _layoutProposer.ResolveOutputName(output);
        var snapshot = _layoutProposer.BuildSnapshotFor(output);
        var target = _layoutProposer.LayoutFocusNeighbor(output, outputName, current, dir, snapshot);
        if (target is { } t && t != IntPtr.Zero && _windowRegistry.Entries.ContainsKey(t))
        {
            _managerRequestSender.ScheduleManage(); // engine may need to recentre viewport
            RequestFocus(t);
            return;
        }

        CycleFocus();
    }

    public void SetFocusedShellSurface(IntPtr shellSurfaceProxy, IntPtr seatProxy)
    {
        _pendingFocus.SetShellSurface(shellSurfaceProxy, seatProxy);
        // Parity with SetFocusedWindow / ClearFocus: ensure the pending focus
        // is actually flushed on the next manage cycle. Without this, if a
        // layer-shell surface (e.g. the start menu) grabs focus just before a
        // new window maps, the pending focus never ships and the new window
        // can't grab keyboard focus either.
        _managerRequestSender.ScheduleManage();
    }

    public void RepairFocusAfterTagChange()
    {
        var focused = _focusedWindow.Current;
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
        _focusedWindow.Current = IntPtr.Zero;
    }

    private IntPtr ResolveSeat()
    {
        IntPtr seat = _primarySeat.Current;
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
