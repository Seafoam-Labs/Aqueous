using System;

namespace Aqueous.Features.Layout;

/// <summary>
/// Seam: the small set of helpers that marshal Wayland requests to <c>river_window_manager_v1</c>
/// and the manage-cycle flush flag.
/// <para>
/// Pump-thread only — every method assumes it is invoked from the Wayland event-dispatch thread.
/// The implementation guards each call with a <c>[Conditional("DEBUG")]</c> affinity assertion
/// that mirrors the existing one in <c>EventDispatcher.Dispatch</c>.
/// </para>
/// <para>
/// Replaces the <c>RiverWindowManagerClient.ManagerRequestSender</c> partial; the partial file is
/// deleted.
/// </para>
/// </summary>
internal interface IManagerRequestSender
{
    /// <summary>
    /// Marshal a no-argument request on the bound <c>river_window_manager_v1</c> proxy and immediately
    /// flush. Silently no-ops if the manager isn't bound yet.
    /// </summary>
    void SendManagerRequest(uint opcode);

    /// <summary>
    /// Ask the compositor to start a new manage sequence so that any state changed outside of one
    /// (pending focus from pointer-enter, Super+Tab, close-and-refocus, drag start) actually gets
    /// flushed promptly. <c>river_window_manager_v1::manage_dirty</c> is opcode 3. No-ops if <see
    /// cref="InsideManageSequence"/> is true (the compositor will flush our pending state when the
    /// current handler returns).
    /// </summary>
    void ScheduleManage();

    /// <summary>
    /// True while we are inside a manage/render sequence. Used by <see cref="ScheduleManage"/> to
    /// short-circuit and avoid extra cycles. Pump-thread mutated only.
    /// </summary>
    bool InsideManageSequence { get; set; }

    /// <summary>
    /// Bind-time initialiser. Called from the registry-binding site where the
    /// <c>river_window_manager_v1</c> proxy + the <c>wl_display*</c> become available. Until called
    /// both pointers are <see cref="IntPtr.Zero"/> and every send is a no-op.
    /// </summary>
    void Init(IntPtr managerProxy, IntPtr display);

    /// <summary>
    /// True iff <see cref="Init"/> has been called with a non-zero manager proxy. Exposed for
    /// diagnostics + tests.
    /// </summary>
    bool IsBound { get; }

    /// <summary>
    /// Teardown counterpart to <see cref="Init"/>. Clears the cached <c>river_window_manager_v1</c>
    /// proxy and <c>wl_display*</c> handles so that subsequent <see cref="SendManagerRequest"/> /
    /// <see cref="ScheduleManage"/> calls become silent no-ops. Must be called when the manager
    /// global is removed (<c>wl_registry::global_remove</c>) or the display is disconnected — once
    /// the proxy is destroyed the stored pointer becomes a dangling write target inside
    /// libwayland's <c>wl_proxy_marshal_flags</c> (the symptom is a NULL-deref at offset 0x2c).
    /// </summary>
    void Reset();

    /// <summary>
    /// Records the managed id of the Wayland event-pump thread. After this call, marshal sites
    /// that detect they are on any other thread will enqueue their work onto the pump-thread
    /// action queue (drained by <see cref="DrainPumpQueue"/>) instead of touching libwayland
    /// directly. Pass <c>0</c> to clear (e.g. on teardown).
    /// </summary>
    void SetPumpThread(int managedThreadId);

    /// <summary>
    /// Drains the pump-thread action queue. MUST be invoked from the Wayland event-pump thread,
    /// once per dispatch iteration. Each queued action runs under a fresh <see cref="IsBound"/>
    /// re-check, so a <see cref="Reset"/> that landed between enqueue and drain turns the marshal
    /// into a silent no-op.
    /// </summary>
    void DrainPumpQueue();

    /// <summary>
    /// True iff the caller is currently running on the Wayland event-pump thread (or the pump has
    /// not started yet, in which case inline execution is safe).
    /// </summary>
    bool IsOnPumpThread { get; }

    /// <summary>
    /// Run <paramref name="action"/> on the pump thread. If the caller is already on the pump
    /// thread (or the pump has not started yet) it runs inline; otherwise it is enqueued onto the
    /// same queue drained by <see cref="DrainPumpQueue"/>. Use for any code that must marshal
    /// Wayland requests from a potentially off-pump caller (e.g. <c>KeyBindingRouter</c>).
    /// </summary>
    void Post(Action action);
}
