using System;
using System.Threading;
using System.Threading.Tasks;
using Aqueous.Diagnostics;
using Aqueous.Features.Compositor.River.Connection;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Connection;

/// <summary>
/// Unit tests for <see cref="EventPump"/> / <see cref="IEventPump"/>.
/// The pump is exercised against an in-memory <see cref="FakeWaylandConnection"/>;
/// libwayland is never touched, so the tests run in any environment.
/// </summary>
public class EventPumpTests
{
    // The defaults used by tests below. Generous enough that a slow
    // CI box doesn't flake, short enough that the suite still runs
    // quickly when everything is healthy.
    private static readonly TimeSpan Short = TimeSpan.FromMilliseconds(50);
    private static readonly TimeSpan Long = TimeSpan.FromSeconds(2);

    private static EventPump NewPump(FakeWaylandConnection conn, EventPumpOptions? options = null)
        => new(conn, NullLogger<EventPump>.Instance, options ?? new EventPumpOptions
        {
            // Tighten the default join so Dispose() in tests is snappy.
            DefaultJoinTimeout = Long,
        });

    [Fact]
    public void Start_IsIdempotent()
    {
        var conn = new FakeWaylandConnection();
        using var pump = NewPump(conn);

        pump.Start();
        var firstThread = conn.WaitForFirstDispatchThread(Long);
        pump.Start(); // second call must be a no-op

        // Give the pump a few iterations; assert all dispatches came
        // from the *same* OS thread, proving no second worker spawned.
        SpinWait.SpinUntil(() => conn.DispatchCalls > 5, Long);
        Assert.True(conn.AllDispatchesOnThread(firstThread));

        pump.Stop(Long);
        Assert.False(pump.IsRunning);
    }

    [Fact]
    public void Start_WhenTokenAlreadyCancelled_DoesNotSpawnThread()
    {
        var conn = new FakeWaylandConnection();
        using var pump = NewPump(conn);
        bool stoppedFired = false;
        pump.Stopped += _ => stoppedFired = true;

        using var cts = new CancellationTokenSource();
        cts.Cancel();
        pump.Start(cts.Token);

        Assert.False(pump.IsRunning);
        Thread.Sleep(20); // give any rogue thread a chance to misbehave
        Assert.False(stoppedFired);
        Assert.Equal(0, conn.DispatchCalls);
    }

    [Fact]
    public void Stop_SetsIsRunningFalseAndJoins()
    {
        var conn = new FakeWaylandConnection();
        using var pump = NewPump(conn);

        pump.Start();
        SpinWait.SpinUntil(() => conn.DispatchCalls > 0, Long);

        pump.Stop(Long);

        Assert.False(pump.IsRunning);
        int snapshot = conn.DispatchCalls;
        Thread.Sleep(20);
        Assert.Equal(snapshot, conn.DispatchCalls); // no further dispatches
    }

    [Fact]
    public void Cancellation_ExitsAtNextIterationBoundary()
    {
        var conn = new FakeWaylandConnection();
        using var pump = NewPump(conn);
        var tcs = new TaskCompletionSource<PumpStopReason>(TaskCreationOptions.RunContinuationsAsynchronously);
        pump.Stopped += r => tcs.TrySetResult(r);

        using var cts = new CancellationTokenSource();
        pump.Start(cts.Token);
        SpinWait.SpinUntil(() => conn.DispatchCalls > 0, Long);
        cts.Cancel();

        Assert.True(tcs.Task.Wait(Long));
        Assert.Equal(PumpStopReason.Cancelled, tcs.Task.Result);
        Assert.False(pump.IsRunning);
    }

    [Fact]
    public void DispatchReturningNegative_ExitsLoopAndRaisesStoppedWithDispatchError()
    {
        var conn = new FakeWaylandConnection { DispatchImpl = () => -1 };
        using var pump = NewPump(conn);
        var tcs = new TaskCompletionSource<PumpStopReason>(TaskCreationOptions.RunContinuationsAsynchronously);
        pump.Stopped += r => tcs.TrySetResult(r);

        pump.Start();

        Assert.True(tcs.Task.Wait(Long));
        Assert.Equal(PumpStopReason.DispatchError, tcs.Task.Result);
        SpinWait.SpinUntil(() => !pump.IsRunning, Long);
        Assert.False(pump.IsRunning);
    }

    [Fact]
    public void DispatchThrowing_RaisesStoppedWithCrashedAndDoesNotPropagate()
    {
        var conn = new FakeWaylandConnection
        {
            DispatchImpl = () => throw new InvalidOperationException("boom"),
        };
        using var pump = NewPump(conn);
        var tcs = new TaskCompletionSource<PumpStopReason>(TaskCreationOptions.RunContinuationsAsynchronously);
        pump.Stopped += r => tcs.TrySetResult(r);

        pump.Start(); // must NOT throw on the calling thread

        Assert.True(tcs.Task.Wait(Long));
        Assert.Equal(PumpStopReason.Crashed, tcs.Task.Result);
    }

    [Fact]
    public void StoppedEvent_RaisedExactlyOnce()
    {
        var conn = new FakeWaylandConnection();
        using var pump = NewPump(conn);
        int count = 0;
        pump.Stopped += _ => Interlocked.Increment(ref count);

        pump.Start();
        SpinWait.SpinUntil(() => conn.DispatchCalls > 0, Long);
        pump.Stop(Long);
        pump.Stop(Long); // second Stop must be a no-op

        Assert.Equal(1, count);
    }

    [Fact]
    public async Task StopAsync_CompletesWhenThreadExits()
    {
        var conn = new FakeWaylandConnection();
        var pump = NewPump(conn);
        try
        {
            pump.Start();
            SpinWait.SpinUntil(() => conn.DispatchCalls > 0, Long);

            await pump.StopAsync(Long);

            Assert.False(pump.IsRunning);
        }
        finally
        {
            pump.Dispose();
        }
    }

    [Fact]
    public async Task StopAsync_RespectsTimeout()
    {
        // Pump that never returns from Dispatch until released.
        var release = new ManualResetEventSlim(initialState: false);
        var conn = new FakeWaylandConnection
        {
            DispatchImpl = () =>
            {
                release.Wait();
                return 0;
            },
        };
        var pump = NewPump(conn);
        try
        {
            pump.Start();
            SpinWait.SpinUntil(() => conn.DispatchCalls > 0, Long);

            await Assert.ThrowsAsync<TimeoutException>(
                async () => await pump.StopAsync(Short));
        }
        finally
        {
            release.Set(); // let the pump actually exit
            pump.Dispose();
        }
    }

    [Fact]
    public void Dispose_StopsThePumpUsingDefaultJoinTimeout()
    {
        var conn = new FakeWaylandConnection();
        var pump = NewPump(conn);
        var tcs = new TaskCompletionSource<PumpStopReason>(TaskCreationOptions.RunContinuationsAsynchronously);
        pump.Stopped += r => tcs.TrySetResult(r);

        pump.Start();
        SpinWait.SpinUntil(() => conn.DispatchCalls > 0, Long);
        pump.Dispose();

        Assert.True(tcs.Task.Wait(Long));
        Assert.Equal(PumpStopReason.StopRequested, tcs.Task.Result);
        Assert.False(pump.IsRunning);
    }

    [Fact]
    public void ThreadName_ComesFromOptions()
    {
        var conn = new FakeWaylandConnection();
        var options = new EventPumpOptions { ThreadName = "Aqueous.TestPumpName" };
        using var pump = NewPump(conn, options);

        pump.Start();
        var thread = conn.WaitForFirstDispatchThread(Long);
        Assert.Equal("Aqueous.TestPumpName", thread.Name);

        pump.Stop(Long);
    }
}
