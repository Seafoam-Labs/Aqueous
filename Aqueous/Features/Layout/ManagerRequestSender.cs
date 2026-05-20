using System;
using Aqueous.Features.Compositor.River;

namespace Aqueous.Features.Layout;

/// <summary>
/// Lift of <c>RiverWindowManagerClient.ManagerRequestSender</c>: owns the small set of helpers
/// that marshal Wayland requests to <c>river_window_manager_v1</c> and the manage-cycle flush
/// flag.
/// <para>
/// Pump-thread only. The <c>_manager</c> and <c>_display</c> handles are owned by libwayland and
/// are valid for the lifetime of the connection; before <see cref="Init"/> fires both are <see
/// cref="IntPtr.Zero"/> and every send is a silent no-op (the registry-binding site may run after
/// some constructor-time consumers, e.g. <c>FocusService</c>).
/// </para>
/// </summary>
internal sealed class ManagerRequestSender : IManagerRequestSender
{
    private IntPtr _manager;
    private IntPtr _display;
    private bool _insideManageSequence;

    public bool InsideManageSequence
    {
        get => _insideManageSequence;
        set => _insideManageSequence = value;
    }

    public bool IsBound => _manager != IntPtr.Zero;

    public void Init(IntPtr managerProxy, IntPtr display)
    {
        _manager = managerProxy;
        _display = display;
    }

    public void SendManagerRequest(uint opcode)
    {
        if (_manager == IntPtr.Zero)
        {
            return;
        }

        WaylandInterop.wl_proxy_marshal_flags(
            _manager, opcode, IntPtr.Zero, 0, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        if (_display != IntPtr.Zero)
        {
            WaylandInterop.wl_display_flush(_display);
        }
    }

    public void ScheduleManage()
    {
        if (_manager == IntPtr.Zero)
        {
            return;
        }
        // If we're already inside a manage/render sequence the compositor will flush our pending state
        // when the current handler returns; issuing manage_dirty now would just guarantee an extra cycle
        // (and a potential infinite loop).
        if (_insideManageSequence)
        {
            return;
        }

        WaylandInterop.wl_proxy_marshal_flags(
            _manager, 3, IntPtr.Zero, 0, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        if (_display != IntPtr.Zero)
        {
            WaylandInterop.wl_display_flush(_display);
        }
    }
}
