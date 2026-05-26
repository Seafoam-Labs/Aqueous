using System;
using System.Threading;
using Aqueous.Features.Compositor.River;

namespace Aqueous.Features.Layout;

/// <summary>
/// Lift of <c>RiverWindowManagerClient.ManagerRequestSender</c>: owns the small set of helpers
/// that marshal Wayland requests to <c>river_window_manager_v1</c> and the manage-cycle flush
/// flag.
/// <para>
/// Pump-thread only for marshalling. The <c>_manager</c> and <c>_display</c> handles are owned
/// by libwayland and are valid for the lifetime of the connection; before <see cref="Init"/>
/// fires both are <see cref="IntPtr.Zero"/> and every send is a silent no-op (the
/// registry-binding site may run after some constructor-time consumers, e.g. <c>FocusService</c>).
/// </para>
/// <para>
/// <see cref="Reset"/> may be called from any thread (e.g. teardown raced against a pump-thread
/// send). Field writes are published with <see cref="Interlocked.Exchange(ref IntPtr, IntPtr)"/>
/// and every marshal site snapshots <c>_manager</c> / <c>_display</c> into locals so a concurrent
/// reset cannot turn a non-null check into a NULL-deref inside libwayland.
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

    // IsBound requires BOTH proxies — flushing _display while it's gone is just as fatal as
    // marshalling against a torn-down _manager. Callers gate on this before reaching the
    // marshal path; the marshal path itself re-snapshots and re-checks.
    public bool IsBound => Volatile.Read(ref _manager) != IntPtr.Zero
                           && Volatile.Read(ref _display) != IntPtr.Zero;

    public void Init(IntPtr managerProxy, IntPtr display)
    {
        Interlocked.Exchange(ref _display, display);
        Interlocked.Exchange(ref _manager, managerProxy);
    }

    public void Reset()
    {
        // Null _manager FIRST so any racing IsBound check fails before _display is cleared;
        // the marshal path's local snapshot will then either see both non-null (and operate on
        // a still-live pair) or see a null _manager and bail out.
        Interlocked.Exchange(ref _manager, IntPtr.Zero);
        Interlocked.Exchange(ref _display, IntPtr.Zero);
        _insideManageSequence = false;
    }

    public void SendManagerRequest(uint opcode)
    {
        var manager = Volatile.Read(ref _manager);
        var display = Volatile.Read(ref _display);
        if (manager == IntPtr.Zero || display == IntPtr.Zero)
        {
            return;
        }

        WaylandInterop.wl_proxy_marshal_flags(
            manager, opcode, IntPtr.Zero, 0, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        WaylandInterop.wl_display_flush(display);
    }

    public void ScheduleManage()
    {
        // If we're already inside a manage/render sequence the compositor will flush our pending state
        // when the current handler returns; issuing manage_dirty now would just guarantee an extra cycle
        // (and a potential infinite loop).
        if (_insideManageSequence)
        {
            return;
        }

        var manager = Volatile.Read(ref _manager);
        var display = Volatile.Read(ref _display);
        if (manager == IntPtr.Zero || display == IntPtr.Zero)
        {
            return;
        }

        WaylandInterop.wl_proxy_marshal_flags(
            manager, 3, IntPtr.Zero, 0, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        WaylandInterop.wl_display_flush(display);
    }
}
