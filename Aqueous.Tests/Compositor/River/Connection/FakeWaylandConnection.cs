using System;
using System.Threading;
using System.Threading.Tasks;
using Aqueous.Diagnostics;
using Aqueous.Features.Compositor.River.Connection;

namespace Aqueous.Tests.Compositor.River.Connection;

/// <summary>
/// Minimal <see cref="IWaylandConnection"/> stand-in used by <see cref="EventPumpTests"/>. Models
/// the poll-based dispatch loop the pump now drives (prepare_read / poll(fd) / read_events) without
/// touching real libwayland.
/// </summary>
/// <remarks>
/// <para>
/// The pump blocks in <c>poll(2)</c> on the fd returned by <see cref="GetFd"/>. To keep the pump
/// iterating (the way the old blocking <c>Dispatch</c> did), <see cref="GetFd"/> returns a real
/// <c>eventfd</c> that is seeded with a non-zero count and never drained, so it is always readable
/// and <c>poll</c> returns immediately. The pluggable <see cref="DispatchImpl"/> body is invoked
/// from <see cref="DispatchPending"/>, which is the loop's per-iteration dispatch point — returning
/// <c>-1</c> there surfaces as <see cref="PumpStopReason.DispatchError"/> and throwing surfaces as
/// <see cref="PumpStopReason.Crashed"/>, exactly as a real dispatch failure would.
/// </para>
/// <para>
/// All counters and thread captures use interlocked / volatile access because the pump invokes the
/// connection from a background thread while the test asserts on the main thread.
/// </para>
/// </remarks>
internal sealed class FakeWaylandConnection : IWaylandConnection
{
    /// <summary>
    /// Pluggable dispatch body, invoked once per pump iteration from <see cref="DispatchPending"/>.
    /// Defaults to "yield + return 0" so the pump iterates rapidly without starving the test thread.
    /// </summary>
    public Func<int> DispatchImpl { get; set; } = () =>
    {
        Thread.Yield();
        return 0;
    };

    private int _dispatchCalls;
    private Thread? _firstDispatchThread;
    private volatile bool _multiThreaded;

    // Real, always-readable eventfd used as the "display" fd so the pump's poll() returns
    // immediately and the loop keeps iterating. Seeded with a non-zero count and never drained.
    private readonly int _displayFd;

    public FakeWaylandConnection()
    {
        _displayFd = PumpNative.eventfd(1, PumpNative.EFD_NONBLOCK | PumpNative.EFD_CLOEXEC);
    }

    /// <summary>
    /// Total number of dispatch invocations observed so far.
    /// </summary>
    public int DispatchCalls => Volatile.Read(ref _dispatchCalls);

    public bool IsConnected => true;

    public IntPtr Display => new(1); // non-zero so guards treat the connection as live

    public Result Connect() => Result.Ok;

    public ValueTask<Result> ConnectAsync(CancellationToken ct) => new(Result.Ok);

    public int Roundtrip() => 0;

    public int Dispatch() => RunDispatch();

    public int DispatchPending() => RunDispatch();

    private int RunDispatch()
    {
        var current = Thread.CurrentThread;
        // Capture the very first thread that ever dispatches; subsequent dispatches on any other
        // thread are recorded and surface as AllDispatchesOnThread == false.
        var prior = Interlocked.CompareExchange(ref _firstDispatchThread, current, null);
        if (prior is not null && prior != current)
        {
            _multiThreaded = true;
        }

        Interlocked.Increment(ref _dispatchCalls);
        return DispatchImpl();
    }

    public int PrepareRead() => 0;

    public int ReadEvents() => 0;

    public void CancelRead()
    {
    }

    public int GetError() => 0;

    public int Flush() => 0;

    public int GetFd() => _displayFd;

    public event Action<string>? Disconnected
    {
        // Unused in pump tests; declared to satisfy the interface.
        add { _ = value; }
        remove { _ = value; }
    }

    public void Dispose()
    {
        if (_displayFd >= 0)
        {
            PumpNative.close(_displayFd);
        }
    }

    /// <summary>
    /// Spins until a dispatch has happened at least once and returns the thread it ran on. Fails the
    /// test (via timeout) rather than blocking forever.
    /// </summary>
    public Thread WaitForFirstDispatchThread(TimeSpan timeout)
    {
        if (!SpinWait.SpinUntil(() => Volatile.Read(ref _firstDispatchThread) is not null, timeout))
        {
            throw new TimeoutException(
                $"Dispatch was not called within {timeout}; check the pump actually started.");
        }

        return Volatile.Read(ref _firstDispatchThread)!;
    }

    /// <summary>
    /// True iff every observed dispatch came from <paramref name="expected"/>.
    /// </summary>
    public bool AllDispatchesOnThread(Thread expected)
        => !_multiThreaded && Volatile.Read(ref _firstDispatchThread) == expected;
}
