using System;

namespace Aqueous.Features.Layout;

/// <summary>
/// Stage 5 seam: the small set of helpers that marshal Wayland requests
/// to <c>river_window_manager_v1</c> and the manage-cycle flush flag.
///
/// <para>
/// Pump-thread only — every method assumes it is invoked from the
/// Wayland event-dispatch thread. The implementation guards each call
/// with a <c>[Conditional("DEBUG")]</c> affinity assertion that mirrors
/// the existing one in <c>EventDispatcher.Dispatch</c>.
/// </para>
///
/// <para>
/// Replaces the <c>RiverWindowManagerClient.ManagerRequestSender</c>
/// partial; the partial file is deleted as part of Stage 5.
/// </para>
/// </summary>
internal interface IManagerRequestSender
{
    /// <summary>
    /// Marshal a no-argument request on the bound
    /// <c>river_window_manager_v1</c> proxy and immediately flush. Silently
    /// no-ops if the manager isn't bound yet.
    /// </summary>
    void SendManagerRequest(uint opcode);

    /// <summary>
    /// Ask the compositor to start a new manage sequence so that any state
    /// changed outside of one (pending focus from pointer-enter, Super+Tab,
    /// close-and-refocus, drag start) actually gets flushed promptly.
    /// <c>river_window_manager_v1::manage_dirty</c> is opcode 3. No-ops if
    /// <see cref="InsideManageSequence"/> is true (the compositor will
    /// flush our pending state when the current handler returns).
    /// </summary>
    void ScheduleManage();

    /// <summary>
    /// True while we are inside a manage/render sequence. Used by
    /// <see cref="ScheduleManage"/> to short-circuit and avoid extra
    /// cycles. Pump-thread mutated only.
    /// </summary>
    bool InsideManageSequence { get; set; }

    /// <summary>
    /// Bind-time initialiser. Called from the registry-binding site
    /// where the <c>river_window_manager_v1</c> proxy + the
    /// <c>wl_display*</c> become available. Until called both pointers
    /// are <see cref="IntPtr.Zero"/> and every send is a no-op.
    /// </summary>
    void Init(IntPtr managerProxy, IntPtr display);

    /// <summary>
    /// True iff <see cref="Init"/> has been called with a non-zero
    /// manager proxy. Exposed for diagnostics + tests.
    /// </summary>
    bool IsBound { get; }
}
