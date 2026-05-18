using System;
using System.Threading;
using System.Threading.Tasks;
using Aqueous.Diagnostics;

namespace Aqueous.Features.Compositor.River.Connection;

/// <summary>
/// Owns the lifetime of a single <c>wl_display</c> connection and the
/// thin set of <c>libwayland-client</c> calls that operate on it. This
/// is the only seam through which higher-level services touch a raw
/// <c>wl_display*</c> pointer.
/// </summary>
/// <remarks>
/// <para>
/// Lifetime is <c>Singleton</c>. Driven externally by the compositor
/// host (currently <see cref="RiverWindowManagerClient"/>, eventually
/// <c>RiverCompositorHost</c>). This service is intentionally
/// <i>not</i> an <c>IHostedService</c>.
/// </para>
/// <para>
/// <b>Threading contract:</b> <see cref="Dispatch"/>,
/// <see cref="DispatchPending"/> and <see cref="Flush"/> must be called
/// from the pump thread only; <see cref="Connect"/>,
/// <see cref="ConnectAsync"/> and <see cref="Roundtrip"/> may be called
/// from the host thread before the pump starts; <see cref="Dispose"/>
/// is safe from any thread.
/// </para>
/// </remarks>
internal interface IWaylandConnection : IDisposable
{
    /// <summary>
    /// True once <see cref="Connect"/> has succeeded and
    /// <see cref="Dispose"/> has not been called.
    /// </summary>
    bool IsConnected { get; }

    /// <summary>
    /// Raw <c>wl_display*</c>. Treat as opaque; never free it. Returns
    /// <see cref="IntPtr.Zero"/> when not connected.
    /// </summary>
    IntPtr Display { get; }

    /// <summary>Opens the default display. Idempotent.</summary>
    Result Connect();

    /// <summary>
    /// Async wrapper around <see cref="Connect"/> for
    /// <c>IHostedService.StartAsync</c> ergonomics. Synchronous under
    /// the covers — libwayland's connect is a blocking syscall.
    /// </summary>
    ValueTask<Result> ConnectAsync(CancellationToken ct);

    /// <summary><c>wl_display_roundtrip</c>. Returns native status.</summary>
    int Roundtrip();

    /// <summary><c>wl_display_dispatch</c>, single iteration. Blocking.</summary>
    int Dispatch();

    /// <summary><c>wl_display_dispatch_pending</c>; non-blocking.</summary>
    int DispatchPending();

    /// <summary><c>wl_display_flush</c>.</summary>
    int Flush();

    /// <summary><c>wl_display_get_fd</c> — for <c>poll</c>/<c>select</c> loops.</summary>
    int GetFd();

    /// <summary>
    /// Raised exactly once when the connection becomes unusable
    /// (libwayland error, EOF, or explicit <see cref="Dispose"/>). The
    /// payload is a short human-readable reason.
    /// </summary>
    event Action<string>? Disconnected;
}
