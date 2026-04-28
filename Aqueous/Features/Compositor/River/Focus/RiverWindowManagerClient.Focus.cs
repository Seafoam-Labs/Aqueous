using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Input;
using Aqueous.Features.Layout;
using Aqueous.Features.State;
using Aqueous.Features.Tags;
namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Focus-related operations for <see cref="RiverWindowManagerClient"/>.
/// Extracted in Phase 2 Step 5 to consolidate focus state mutations
/// (SetFocusedWindow / RequestFocus / ClearFocus / FocusAnyOtherWindow /
/// CycleFocus / HandleDirectionalFocus / SetFocusedShellSurface) in one
/// place. Kept as a partial class because every method reaches into
/// private fields (_windows, _seats, _primarySeat, _layoutController,
/// ScheduleManage); a fully extracted FocusController belongs after the
/// façade reduction in Step 7.
/// </summary>
internal sealed unsafe partial class RiverWindowManagerClient
{
    public void SetFocusedWindow(IntPtr windowProxy, IntPtr seatProxy)
    {
        // Fix #1: skip no-op focus changes. SetFocusedWindow is called from
        // pointer_enter on every mouse crossing; without a correct guard each
        // enter event would issue manage_dirty, creating a manage/render storm
        // that starves other clients' wl_display pings (they die after ~60s).
        // The previous guard only fired when both pending fields were zero,
        // but _pendingFocusWindow stays non-zero between manage_start cycles,
        // so the guard never tripped again during pointer motion.
        if (windowProxy == _focusedWindow && _pendingFocusWindow == windowProxy)
        {
            return; // same focus already pending
        }

        if (windowProxy == _focusedWindow && _pendingFocusWindow == IntPtr.Zero &&
            _pendingFocusShellSurface == IntPtr.Zero)
        {
            return; // already focused and applied
        }

        _pendingFocusWindow = windowProxy;
        _pendingFocusShellSurface = IntPtr.Zero;
        _pendingFocusSeat = seatProxy;
        _focusedWindow = windowProxy;
        ScheduleManage();
    }

    /// <summary>
    /// Request focus for the given window. Uses the primary seat when no seat is provided.
    /// The focus request is stashed and flushed during the next manage_start.
    /// </summary>
    private void RequestFocus(IntPtr windowProxy)
    {
        IntPtr seat = _primarySeat;
        if (seat == IntPtr.Zero)
        {
            foreach (var k in _seats.Keys)
            {
                seat = k;
                break;
            }
        }

        if (seat == IntPtr.Zero)
        {
            return;
        }

        SetFocusedWindow(windowProxy, seat);
    }

    /// <summary>Clear focus on the primary seat (river_seat_v1::clear_focus, opcode 3).</summary>
    private void ClearFocus()
    {
        IntPtr seat = _primarySeat;
        if (seat == IntPtr.Zero)
        {
            foreach (var k in _seats.Keys)
            {
                seat = k;
                break;
            }
        }

        _pendingFocusWindow = IntPtr.Zero;
        _pendingFocusShellSurface = IntPtr.Zero;
        _pendingFocusSeat = IntPtr.Zero;
        _focusedWindow = IntPtr.Zero;
        if (seat != IntPtr.Zero)
        {
            WaylandInterop.wl_proxy_marshal_flags(seat, 3, IntPtr.Zero, 0, 0,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            Log($"clear_focus on seat 0x{seat.ToString("x")}");
        }

        ScheduleManage();
    }

    /// <summary>Pick any window (prefer not-currently-focused) and focus it. No-op if empty.</summary>
    private void FocusAnyOtherWindow(IntPtr avoid)
    {
        IntPtr pick = IntPtr.Zero;
        foreach (var k in _windows.Keys)
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
            foreach (var k in _windows.Keys)
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

    /// <summary>Advance keyboard focus to the next window in _windows iteration order.</summary>
    private void CycleFocus()
    {
        if (_windows.Count == 0)
        {
            return;
        }

        IntPtr next = IntPtr.Zero;
        bool takeNext = false;
        foreach (var k in _windows.Keys)
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

            if (k == _focusedWindow)
            {
                takeNext = true;
            }
        }

        if (next != IntPtr.Zero)
        {
            RequestFocus(next);
        }
    }

    private void HandleDirectionalFocus(FocusDirection dir)
    {
        if (_focusedWindow == IntPtr.Zero || _windows.Count == 0)
        {
            CycleFocus();
            return;
        }

        if (!_windows.TryGetValue(_focusedWindow, out var fw))
        {
            CycleFocus();
            return;
        }

        IntPtr output = fw.Output;
        string? outputName = ResolveOutputName(output);
        var snapshot = BuildSnapshotFor(output);
        var target = _layoutController.FocusNeighbor(output, outputName, _focusedWindow, dir, snapshot);
        if (target is { } t && t != IntPtr.Zero && _windows.ContainsKey(t))
        {
            ScheduleManage(); // engine may need to recentre viewport
            RequestFocus(t);
            return;
        }

        CycleFocus();
    }

    public void SetFocusedShellSurface(IntPtr shellSurfaceProxy, IntPtr seatProxy)
    {
        _pendingFocusShellSurface = shellSurfaceProxy;
        _pendingFocusWindow = IntPtr.Zero;
        _pendingFocusSeat = seatProxy;
        // Parity with SetFocusedWindow / ClearFocus: ensure the pending focus
        // is actually flushed on the next manage cycle. Without this, if a
        // layer-shell surface (e.g. the start menu) grabs focus just before a
        // new window maps, the pending focus never ships and the new window
        // can't grab keyboard focus either.
        ScheduleManage();
    }
}
