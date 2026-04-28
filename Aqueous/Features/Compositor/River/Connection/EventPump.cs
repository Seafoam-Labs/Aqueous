using System;
using System.Threading;

namespace Aqueous.Features.Compositor.River.Connection;

/// <summary>
/// Runs the Wayland event-dispatch loop on a dedicated background
/// thread. Each iteration calls <see cref="WaylandConnection.Dispatch"/>;
/// the loop exits when libwayland reports an error (return value &lt; 0),
/// when <see cref="Stop"/> is invoked, or when the
/// <see cref="CancellationToken"/> passed to <see cref="Start"/> is
/// cancelled.
/// </summary>
/// <remarks>
/// <para>
/// The pump does not own the connection — it only reads from it — so
/// shutdown is the caller's responsibility: typically
/// <see cref="Stop"/> first (to leave the loop), then
/// <see cref="WaylandConnection.Disconnect"/> (to release the
/// <c>wl_display*</c>).
/// </para>
/// <para>
/// <b>Cancellation contract:</b> <c>wl_display_dispatch</c> blocks on
/// the display fd until an event arrives. The cancellation token is
/// therefore checked on every iteration <em>boundary</em>, not while
/// waiting on the fd. In practice River sends frequent events so this
/// is responsive in normal operation; for a hard guarantee, callers can
/// invoke <see cref="Stop"/> directly which sets the running flag and
/// joins.
/// </para>
/// </remarks>
internal sealed class EventPump : IDisposable
{
    private readonly WaylandConnection _connection;
    private readonly Action<string> _log;
    private Thread? _thread;
    private volatile bool _running;
    private CancellationTokenSource? _internalCts;
    private CancellationTokenRegistration _externalRegistration;

    public EventPump(WaylandConnection connection, Action<string> log)
    {
        _connection = connection;
        _log = log;
    }

    /// <summary>True while the pump thread is actively dispatching.</summary>
    public bool IsRunning => _running;

    /// <summary>
    /// Spawns the background pump thread. Idempotent: a second call
    /// while already running is a no-op. If <paramref name="externalToken"/>
    /// is cancelled, the pump exits at the next iteration boundary.
    /// </summary>
    public void Start(CancellationToken externalToken = default)
    {
        if (_running)
        {
            return;
        }

        if (externalToken.IsCancellationRequested)
        {
            // Caller already cancelled — don't spawn a thread that
            // would immediately exit.
            return;
        }

        _internalCts = new CancellationTokenSource();
        _externalRegistration = externalToken.CanBeCanceled
            ? externalToken.Register(static cts => ((CancellationTokenSource)cts!).Cancel(), _internalCts)
            : default;

        _running = true;
        _thread = new Thread(PumpLoop)
        {
            IsBackground = true,
            Name = "Aqueous.RiverWindowManager",
        };
        _thread.Start();
    }

    /// <summary>
    /// Signals the pump to exit at the next iteration boundary and waits
    /// up to <paramref name="joinTimeoutMs"/> milliseconds for the
    /// thread to terminate. Idempotent.
    /// </summary>
    public void Stop(int joinTimeoutMs = 500)
    {
        _running = false;
        try
        {
            _internalCts?.Cancel();
        }
        catch (ObjectDisposedException)
        {
            // Already disposed — fine.
        }

        try
        {
            _thread?.Join(joinTimeoutMs);
        }
        catch
        {
            // Joining a never-started thread or one that's already gone
            // is fine; we don't have a useful action to take here.
        }

        _externalRegistration.Dispose();
        _externalRegistration = default;
        _internalCts?.Dispose();
        _internalCts = null;
        _thread = null;
    }

    private void PumpLoop()
    {
        var token = _internalCts?.Token ?? CancellationToken.None;
        try
        {
            while (_running && !token.IsCancellationRequested)
            {
                int r = _connection.Dispatch();
                if (r < 0)
                {
                    _log("wl_display_dispatch returned < 0; pump exiting");
                    break;
                }
            }
        }
        catch (Exception e)
        {
            _log("pump crashed: " + e.Message);
        }
    }

    public void Dispose() => Stop();
}
