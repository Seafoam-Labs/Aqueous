using System;
using System.Threading;

namespace Aqueous.Features.Compositor.River.Connection;

/// <summary>
/// Runs the Wayland event-dispatch loop on a dedicated background
/// thread. Each iteration calls <see cref="WaylandConnection.Dispatch"/>;
/// the loop exits when libwayland reports an error (return value &lt; 0)
/// or when <see cref="Stop"/> is invoked.
/// </summary>
/// <remarks>
/// The pump does not own the connection — it only reads from it — so
/// shutdown is the caller's responsibility: typically
/// <see cref="Stop"/> first (to leave the loop), then
/// <see cref="WaylandConnection.Disconnect"/> (to release the
/// <c>wl_display*</c>).
/// </remarks>
internal sealed class EventPump : IDisposable
{
    private readonly WaylandConnection _connection;
    private readonly Action<string> _log;
    private Thread? _thread;
    private volatile bool _running;

    public EventPump(WaylandConnection connection, Action<string> log)
    {
        _connection = connection;
        _log = log;
    }

    /// <summary>True while the pump thread is actively dispatching.</summary>
    public bool IsRunning => _running;

    /// <summary>
    /// Spawns the background pump thread. Idempotent: a second call
    /// while already running is a no-op.
    /// </summary>
    public void Start()
    {
        if (_running)
        {
            return;
        }

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
    /// thread to terminate.
    /// </summary>
    public void Stop(int joinTimeoutMs = 500)
    {
        _running = false;
        try
        {
            _thread?.Join(joinTimeoutMs);
        }
        catch
        {
            // Joining a never-started thread or one that's already gone
            // is fine; we don't have a useful action to take here.
        }
        _thread = null;
    }

    private void PumpLoop()
    {
        try
        {
            while (_running)
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
