using System;
using System.Runtime.InteropServices;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Manager-request-sending partial of <see cref="RiverWindowManagerClient"/>:
/// owns the small set of helpers that actually marshal Wayland requests to
/// <c>river_window_manager_v1</c> and the one shared UTF-8 marshalling
/// utility. Kept separate from <c>LayoutProposer</c> so the place where we
/// "talk to the compositor" is one short, auditable file.
/// </summary>
internal sealed unsafe partial class RiverWindowManagerClient
{
    /// <summary>
    /// Marshal a no-argument request on the bound <c>river_window_manager_v1</c>
    /// proxy at <paramref name="opcode"/> and immediately flush. Silently
    /// no-ops if the manager isn't bound yet.
    /// </summary>
    private void SendManagerRequest(uint opcode)
    {
        if (_manager == IntPtr.Zero)
        {
            return;
        }

        WaylandInterop.wl_proxy_marshal_flags(
            _manager, opcode, IntPtr.Zero, 0, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        WaylandInterop.wl_display_flush(_display);
    }

    /// <summary>
    /// Ask the compositor to start a new manage sequence so that any state we
    /// changed outside of one (pending focus from pointer-enter, Super+Tab,
    /// close-and-refocus, drag start) actually gets flushed promptly.
    /// river_window_manager_v1::manage_dirty is opcode 3.
    /// </summary>
    private void ScheduleManage()
    {
        if (_manager == IntPtr.Zero)
        {
            return;
        }
        // If we're already inside a manage/render sequence the compositor will flush
        // our pending state when the current handler returns; issuing manage_dirty now
        // would just guarantee an extra cycle (and a potential infinite loop).
        if (_insideManageSequence)
        {
            return;
        }

        WaylandInterop.wl_proxy_marshal_flags(_manager, 3, IntPtr.Zero, 0, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        WaylandInterop.wl_display_flush(_display);
    }

    private static string? MarshalUtf8(IntPtr p)
        => p == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(p);
}
