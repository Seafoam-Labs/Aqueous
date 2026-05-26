using System;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Aqueous.Features.Compositor.River.Connection;

/// <summary>
/// Default <see cref="IEventPump"/> implementation. Runs a single background thread that invokes
/// <see cref="IWaylandConnection.Dispatch"/> in a loop until told otherwise. See <see
/// cref="IEventPump"/> for the full contract.
/// </summary>
internal sealed class EventPump : IEventPump
{
    private readonly IWaylandConnection _connection;
    private readonly ILogger<EventPump> _logger;
    private readonly EventPumpOptions _options;

    // Single lock guarding lifecycle transitions (Start/Stop). The pump loop itself does not take the
    // lock; it observes _running and the linked-token instead.
    private readonly object _gate = new();

    private Thread? _thread;
    private volatile bool _running;
    private CancellationTokenSource? _internalCts;
    private CancellationTokenRegistration _externalRegistration;
    private TaskCompletionSource? _stoppedTcs;
    private PumpStopReason _stopReason;
    private bool _stopRequested;

    public EventPump(IWaylandConnection connection)
        : this(connection, NullLogger<EventPump>.Instance, new EventPumpOptions())
    {
    }

    public EventPump(IWaylandConnection connection, ILogger<EventPump> logger, EventPumpOptions options)
    {
        _connection = connection ?? throw new ArgumentNullException(nameof(connection));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _options = options ?? throw new ArgumentNullException(nameof(options));
    }

    public bool IsRunning => _running;

    public event Action<PumpStopReason>? Stopped;

    public void Start(CancellationToken ct = default)
    {
        lock (_gate)
        {
            if (_running)
            {
                return;
            }

            if (ct.IsCancellationRequested)
            {
                // Caller already cancelled — don't spawn a thread that would immediately exit. No Stopped event
                // because we never started.
                return;
            }

            _stopRequested = false;
            _stopReason = PumpStopReason.StopRequested;
            _stoppedTcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

            _internalCts = new CancellationTokenSource();
            _externalRegistration = ct.CanBeCanceled
                ? ct.Register(static cts => ((CancellationTokenSource)cts!).Cancel(), _internalCts)
                : default;

            _running = true;
            _thread = new Thread(PumpLoop)
            {
                IsBackground = true,
                Name = _options.ThreadName,
            };
            _thread.Start();
        }
    }

    public void Stop(TimeSpan joinTimeout)
    {
        Thread? thread;
        lock (_gate)
        {
            thread = _thread;
            if (thread is null)
            {
                // Already stopped (or never started). Strict no-op.
                return;
            }

            _stopRequested = true;
            _running = false;
            try
            {
                _internalCts?.Cancel();
            }
            catch (ObjectDisposedException)
            {
                // Already disposed — fine.
            }
        }

        // If Stop is invoked from inside the pump thread itself (e.g. a protocol event handler calling
        // _pump.Stop(.)), joining would deadlock and tearing down _internalCts / _stoppedTcs out from
        // under the pump's finally block races the Stopped event. Just signal exit and return; the pump
        // unwinds on its own and CleanupAfterStop runs on the next external Stop/Dispose call.
        if (Thread.CurrentThread == thread)
        {
            return;
        }

        // Join outside the lock so the pump thread can complete its own teardown (raising Stopped,
        // completing the TCS).
        try
        {
            thread.Join(joinTimeout);
        }
        catch
        {
            // Joining a never-started thread or one that's already gone is fine; we don't have a useful
            // action to take.
        }

        CleanupAfterStop();
    }

    public async Task StopAsync(TimeSpan joinTimeout, CancellationToken ct = default)
    {
        Task? task;
        lock (_gate)
        {
            if (_thread is null)
            {
                return;
            }

            task = _stoppedTcs?.Task;
            _stopRequested = true;
            _running = false;
            try
            {
                _internalCts?.Cancel();
            }
            catch (ObjectDisposedException)
            {
                // Already disposed — fine.
            }
        }

        if (task is not null)
        {
            try
            {
                await task.WaitAsync(joinTimeout, ct).ConfigureAwait(false);
            }
            catch (TimeoutException)
            {
                // Propagate per the documented contract; do NOT clean up because the pump thread is still running
                // and owns _internalCts / _externalRegistration.
                throw;
            }
        }

        // Best-effort join (the TCS already completed, so this is essentially zero-wait) before tearing
        // down shared state.
        Thread? thread;
        lock (_gate)
        {
            thread = _thread;
        }

        try
        {
            thread?.Join(joinTimeout);
        }
        catch
        {
            // See Stop rationale.
        }

        CleanupAfterStop();
    }

    private void CleanupAfterStop()
    {
        lock (_gate)
        {
            _externalRegistration.Dispose();
            _externalRegistration = default;
            _internalCts?.Dispose();
            _internalCts = null;
            _thread = null;
            _stoppedTcs = null;
        }
    }

    private void PumpLoop()
    {
        var token = _internalCts?.Token ?? CancellationToken.None;
        PumpStopReason reason = PumpStopReason.StopRequested;
        try
        {
            try
            {
                _options.OnPumpThreadStart?.Invoke();
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "OnPumpThreadStart handler threw");
            }

            while (_running)
            {
                if (token.IsCancellationRequested)
                {
                    reason = _stopRequested
                        ? PumpStopReason.StopRequested
                        : PumpStopReason.Cancelled;
                    break;
                }

                int r;
                try
                {
                    r = _connection.Dispatch();
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "pump crashed inside wl_display_dispatch");
                    reason = PumpStopReason.Crashed;
                    break;
                }

                if (_options.VerboseDispatchTrace)
                {
                    _logger.LogTrace("wl_display_dispatch returned {Code}", r);
                }

                if (r < 0)
                {
                    _logger.LogWarning("wl_display_dispatch returned {Code}; pump exiting", r);
                    reason = PumpStopReason.DispatchError;
                    break;
                }

                try
                {
                    _options.OnDispatchIteration?.Invoke();
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "OnDispatchIteration handler threw");
                }
            }

            // If the while-condition itself fell through (_running was set false without
            // internal-cancellation firing first), that means Stop raced us; treat as StopRequested.
            if (!_running && !token.IsCancellationRequested && reason == PumpStopReason.StopRequested)
            {
                reason = PumpStopReason.StopRequested;
            }
        }
        catch (Exception ex)
        {
            // Defensive: anything escaping the inner try/catch is still bounded here so the process is never
            // taken down by the pump thread.
            _logger.LogError(ex, "pump loop crashed");
            reason = PumpStopReason.Crashed;
        }
        finally
        {
            try
            {
                _options.OnPumpThreadStop?.Invoke();
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "OnPumpThreadStop handler threw");
            }

            _running = false;
            _stopReason = reason;

            // Complete the TCS first so StopAsync can return, then raise the event. Capturing locals avoids
            // racing with CleanupAfterStop (which may null _stoppedTcs after Stop's Join returns).
            var tcs = _stoppedTcs;
            tcs?.TrySetResult();

            try
            {
                Stopped?.Invoke(reason);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Stopped handler threw");
            }
        }
    }

    public void Dispose() => Stop(_options.DefaultJoinTimeout);
}
