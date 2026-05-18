using System;
using System.Threading;
using System.Threading.Tasks;
using Aqueous.Diagnostics;
using Aqueous.Features.Compositor.River.Connection;

namespace Aqueous.Tests.Compositor.River.Connection;

/// <summary>
/// Minimal <see cref="IWaylandConnection"/> stand-in used by
/// <see cref="EventPumpTests"/>. Only <c>Dispatch</c> is wired up;
/// every other member throws so an accidental call is loud.
/// </summary>
/// <remarks>
/// All counters and thread captures use interlocked / volatile
/// access because the pump invokes <c>Dispatch</c> from a background
/// thread while the test asserts on the main thread.
/// </remarks>
internal sealed class FakeWaylandConnection : IWaylandConnection
{
    /// <summary>
    /// Pluggable <c>Dispatch</c> body. Defaults to "yield + return 0"
    /// so the pump iterates rapidly without starving the test
    /// thread of CPU.
    /// </summary>
    public Func<int> DispatchImpl { get; set; } = () =>
    {
        Thread.Yield();
        return 0;
    };

    private int _dispatchCalls;

    /// <summary>Total number of <c>Dispatch</c> calls observed so far.</summary>
    public int DispatchCalls => Volatile.Read(ref _dispatchCalls);

    private Thread? _firstDispatchThread;
    private volatile bool _multiThreaded;

    public bool IsConnected => true;

    public IntPtr Display => IntPtr.Zero;

    public Result Connect() => Result.Ok;

    public ValueTask<Result> ConnectAsync(CancellationToken ct) => new(Result.Ok);

    public int Roundtrip() => 0;

    public int Dispatch()
    {
        var current = Thread.CurrentThread;
        // Capture the very first thread that ever calls Dispatch;
        // subsequent dispatches on any other thread are recorded
        // and surface as AllDispatchesOnThread() == false.
        var prior = Interlocked.CompareExchange(ref _firstDispatchThread, current, null);
        if (prior is not null && prior != current)
        {
            _multiThreaded = true;
        }

        Interlocked.Increment(ref _dispatchCalls);
        return DispatchImpl();
    }

    public int DispatchPending() => 0;

    public int Flush() => 0;

    public int GetFd() => -1;

    public event Action<string>? Disconnected
    {
        // Unused in pump tests; declared to satisfy the interface.
        add { _ = value; }
        remove { _ = value; }
    }

    public void Dispose()
    {
        // No native resources.
    }

    /// <summary>
    /// Spins until <c>Dispatch</c> has been called at least once and
    /// returns the thread it ran on. Fails the test (via timeout)
    /// rather than blocking forever.
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

    /// <summary>True iff every observed <c>Dispatch</c> call came from
    /// <paramref name="expected"/>.</summary>
    public bool AllDispatchesOnThread(Thread expected)
        => !_multiThreaded && Volatile.Read(ref _firstDispatchThread) == expected;
}
