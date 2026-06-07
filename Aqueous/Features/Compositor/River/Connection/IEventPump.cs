using System;
using System.Threading;
using System.Threading.Tasks;

namespace Aqueous.Features.Compositor.River.Connection;

/// <summary>
/// Owns the single background thread that drives <see cref="IWaylandConnection.Dispatch"/> in a
/// loop. This is the only component allowed to spawn or join the Wayland pump thread.
/// </summary>
/// <remarks>
/// <para>
/// Lifetime is <c>Singleton</c>. Driven externally by the compositor host (currently <see
/// cref="RiverWindowManagerClient"/>, eventually <c>RiverCompositorHost</c>). This service is
/// intentionally <i>not</i> an <c>IHostedService</c>.
/// </para>
/// <para>
/// <b>Threading contract:</b> <see cref="Start"/>, <see cref="Stop"/>, <see cref="StopAsync"/>,
/// <see cref="IDisposable.Dispose"/> and <see cref="IsRunning"/> are safe from any thread. <see
/// cref="Stopped"/> is raised <em>on the pump thread</em> just before it terminates; handlers must
/// not block.
/// </para>
/// <para>
/// <b>Cancellation contract:</b> <c>wl_display_dispatch</c> blocks on the display fd. Cancellation
/// is therefore observed at iteration <em>boundaries</em>, not while blocked on the fd. In
/// practice River emits events frequently enough for this to be responsive; callers that need a
/// hard guarantee should call <see cref="Stop"/> explicitly.
/// </para>
/// <para>
/// <b>Ordering rule:</b> <see cref="IWaylandConnection.Dispose"/> must <em>not</em> be invoked
/// until <see cref="StopAsync"/> (or <see cref="Stop"/>) has completed. Disposing the display
/// while the pump is blocked inside <c>wl_display_dispatch</c> is undefined behaviour in
/// libwayland.
/// </para>
/// </remarks>
internal interface IEventPump : IDisposable
{
    /// <summary>
    /// True while the pump thread is actively dispatching.
    /// </summary>
    bool IsRunning { get; }

    /// <summary>
    /// Spawns the background pump thread. Idempotent: a second call while already running is a no-op.
    /// If <paramref name="ct"/> is cancelled, the pump exits at the next iteration boundary.
    /// </summary>
    void Start(CancellationToken ct = default);

    /// <summary>
    /// Signals the pump to exit (waking it immediately via the wakeup fd) and waits up to <paramref
    /// name="joinTimeout"/> for the thread to terminate. Idempotent. Returns <c>true</c> if the pump
    /// thread has actually exited (or was never running); <c>false</c> if the join timed out and the
    /// thread may still be inside libwayland — in which case the caller MUST NOT disconnect.
    /// </summary>
    bool Stop(TimeSpan joinTimeout);

    /// <summary>
    /// Awaitable variant of <see cref="Stop"/> for <c>IHostedService.StopAsync</c> ergonomics. Throws
    /// <see cref="TimeoutException"/> if the pump thread fails to exit within <paramref
    /// name="joinTimeout"/>.
    /// </summary>
    Task StopAsync(TimeSpan joinTimeout, CancellationToken ct = default);

    /// <summary>
    /// Raised exactly once when the pump thread has exited, regardless of cause (clean stop,
    /// cancellation, libwayland error, or crash). The argument describes the reason. Invoked on the
    /// pump thread.
    /// </summary>
    event Action<PumpStopReason>? Stopped;
}

/// <summary>
/// Reason the <see cref="IEventPump"/> background thread exited. Reported via <see
/// cref="IEventPump.Stopped"/>.
/// </summary>
internal enum PumpStopReason
{
    /// <summary>
    /// <see cref="IEventPump.Stop"/> Or <see cref="IEventPump.StopAsync"/> was invoked.
    /// </summary>
    StopRequested,

    /// <summary>
    /// The <see cref="CancellationToken"/> passed to <see cref="IEventPump.Start"/> was cancelled.
    /// </summary>
    Cancelled,

    /// <summary>
    /// <c>wl_display_dispatch</c> Returned a value &lt; 0.
    /// </summary>
    DispatchError,

    /// <summary>
    /// A managed exception escaped <see cref="IWaylandConnection.Dispatch"/>.
    /// </summary>
    Crashed,
}
