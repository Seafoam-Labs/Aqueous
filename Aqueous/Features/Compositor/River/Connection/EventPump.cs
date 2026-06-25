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

    // Thread-safe wakeup primitive. wl_display_dispatch (blocking) gave the pump no way to be woken
    // mid-call, so Stop had to wait out a timeout while the thread was parked inside libwayland —
    // then wl_display_disconnect ran on top of it (the `segfault at 2c` teardown race). We now block
    // in poll() on BOTH the display fd and this eventfd; Wake() writes one token to make poll return
    // immediately so the pump exits a wl_display_* call cleanly before disconnect.
    private int _wakeFd = -1;

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

            // Create the wakeup eventfd before the thread starts so Wake() (from Stop) can never race
            // a not-yet-created fd. EFD_NONBLOCK so draining never blocks; EFD_CLOEXEC for hygiene.
            _wakeFd = PumpNative.eventfd(0, PumpNative.EFD_NONBLOCK | PumpNative.EFD_CLOEXEC);
            if (_wakeFd < 0)
            {
                _logger.LogWarning("eventfd() failed; pump wakeup will fall back to poll timeout");
            }

            _running = true;
            _thread = new Thread(PumpLoop)
            {
                IsBackground = true,
                Name = _options.ThreadName,
            };
            _thread.Start();
        }
    }

    public bool Stop(TimeSpan joinTimeout)
    {
        Thread? thread;
        lock (_gate)
        {
            thread = _thread;
            if (thread is null)
            {
                // Already stopped (or never started). Strict no-op — treat as "exited".
                return true;
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

        // Wake the pump out of its poll() immediately so it exits a wl_display_* call cleanly instead
        // of waiting out the join timeout parked inside libwayland.
        Wake();

        // If Stop is invoked from inside the pump thread itself (e.g. a protocol event handler calling
        // _pump.Stop(.)), joining would deadlock and tearing down _internalCts / _stoppedTcs out from
        // under the pump's finally block races the Stopped event. Just signal exit and return; the pump
        // unwinds on its own and CleanupAfterStop runs on the next external Stop/Dispose call.
        if (Thread.CurrentThread == thread)
        {
            return false;
        }

        // Join outside the lock so the pump thread can complete its own teardown (raising Stopped,
        // completing the TCS).
        bool joined;
        try
        {
            joined = thread.Join(joinTimeout);
        }
        catch
        {
            // Joining a never-started thread or one that's already gone is fine; we don't have a useful
            // action to take.
            joined = false;
        }

        if (joined)
        {
            CleanupAfterStop();
        }

        return joined;
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

        // Wake the pump out of poll() immediately (see Stop).
        Wake();

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

            if (_wakeFd >= 0)
            {
                PumpNative.close(_wakeFd);
                _wakeFd = -1;
            }
        }
    }

    // Writes one token to the wakeup eventfd so the pump's poll() returns immediately. Safe to call
    // from any thread; a failed/absent fd just means the pump falls back to its poll timeout.
    private void Wake()
    {
        int fd = Volatile.Read(ref _wakeFd);
        if (fd < 0)
        {
            return;
        }

        ulong one = 1;
        try
        {
            PumpNative.write(fd, ref one, sizeof(ulong));
        }
        catch
        {
            // Best-effort wake; the poll timeout is the safety net.
        }
    }

    private void DrainWake()
    {
        int fd = Volatile.Read(ref _wakeFd);
        if (fd < 0)
        {
            return;
        }

        ulong sink = 0;
        try
        {
            PumpNative.read(fd, ref sink, sizeof(ulong));
        }
        catch
        {
            // EAGAIN (nothing to drain) is expected and harmless.
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

            // Poll-based thread-safe dispatch. Instead of the old blocking wl_display_dispatch (which
            // could only observe cancellation BETWEEN iterations, leaving the thread parked inside
            // libwayland during teardown), we drive the prepare_read / poll / read_events pattern and
            // block in poll() on both the display fd and the wakeup eventfd. Stop()/StopAsync() write
            // to the wakeup fd so poll returns immediately, letting the pump leave every wl_display_*
            // call cleanly (CancelRead on the wakeup path) before wl_display_disconnect runs.
            while (_running)
            {
                if (token.IsCancellationRequested)
                {
                    reason = _stopRequested
                        ? PumpStopReason.StopRequested
                        : PumpStopReason.Cancelled;
                    break;
                }

                try
                {
                    // 1) Drain anything already queued without touching the socket.
                    if (_connection.DispatchPending() < 0)
                    {
                        reason = PumpStopReason.DispatchError;
                        break;
                    }

                    // 2) Announce intent to read. A non-zero return means events are still queued for
                    //    the default queue: dispatch them and retry until prepare_read succeeds.
                    int prep;
                    while ((prep = _connection.PrepareRead()) != 0)
                    {
                        if (!_running || token.IsCancellationRequested)
                        {
                            if (token.IsCancellationRequested)
                            {
                                reason = _stopRequested
                                    ? PumpStopReason.StopRequested
                                    : PumpStopReason.Cancelled;
                            }

                            break;
                        }

                        if (_connection.DispatchPending() < 0)
                        {
                            reason = PumpStopReason.DispatchError;
                            goto exitLoop;
                        }
                    }

                    bool readPrepared = prep == 0;

                    if (!_running || token.IsCancellationRequested)
                    {
                        // Stop raced us between preparing the read and entering poll. Any successfully
                        // prepared read MUST be cancelled so the display is left clean for disconnect.
                        if (token.IsCancellationRequested)
                        {
                            reason = _stopRequested
                                ? PumpStopReason.StopRequested
                                : PumpStopReason.Cancelled;
                        }

                        if (readPrepared)
                        {
                            _connection.CancelRead();
                        }
                        break;
                    }

                    // 3) Flush our outbound buffer before sleeping in poll().
                    _connection.Flush();

                    // 4) Block on BOTH the display fd and the wakeup fd.
                    int displayFd = _connection.GetFd();
                    if (displayFd < 0)
                    {
                        _connection.CancelRead();
                        reason = PumpStopReason.DispatchError;
                        break;
                    }

                    int wakeFd = Volatile.Read(ref _wakeFd);
                    var fds = wakeFd >= 0
                        ? new[]
                        {
                            new PumpNative.PollFd { fd = displayFd, events = PumpNative.POLLIN },
                            new PumpNative.PollFd { fd = wakeFd, events = PumpNative.POLLIN },
                        }
                        : new[]
                        {
                            new PumpNative.PollFd { fd = displayFd, events = PumpNative.POLLIN },
                        };

                    // Timeout is the safety net for the (logged) case where the wakeup fd could not be
                    // created; with the fd present the wake is instant.
                    int pollTimeoutMs = wakeFd >= 0 ? -1 : 200;
                    int pr = PumpNative.poll(fds, (nuint)fds.Length, pollTimeoutMs);

                    if (pr < 0)
                    {
                        // EINTR etc. — abandon this read, loop and re-evaluate _running.
                        _connection.CancelRead();
                        continue;
                    }

                    // 5) Wakeup fd fired -> stop requested. Cancel the prepared read and exit cleanly.
                    if (wakeFd >= 0 && (fds[1].revents & PumpNative.POLLIN) != 0)
                    {
                        _connection.CancelRead();
                        DrainWake();
                        reason = PumpStopReason.StopRequested;
                        break;
                    }

                    if (pr == 0)
                    {
                        // poll() timed out (no-wakeup-fd fallback). Nothing to read.
                        _connection.CancelRead();
                        continue;
                    }

                    // 6) Display fd readable -> read events into the queue, then dispatch them.
                    if (_connection.ReadEvents() < 0)
                    {
                        reason = PumpStopReason.DispatchError;
                        break;
                    }

                    if (_connection.DispatchPending() < 0)
                    {
                        reason = PumpStopReason.DispatchError;
                        break;
                    }
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "pump crashed inside wl_display dispatch cycle");
                    reason = PumpStopReason.Crashed;
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

            exitLoop: ;

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
