using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Threading;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Dispatch-thread guard rails for <see cref="RiverWindowManagerClient"/>.
///
/// <para>
/// Wayland dispatch is logically single-threaded — every event arrives via
/// the <c>[UnmanagedCallersOnly] Dispatch</c> entry point on the
/// <see cref="Aqueous.Features.Compositor.River.Connection.EventPump"/>'s
/// dedicated background thread. WM state (<c>_windows</c>, <c>_focusedWindow</c>,
/// <c>_pendingFocusWindow</c>, …) must only be mutated from there; if any
/// background task (input-daemon socket reader, screencopy frame callback,
/// async layout work) mutates that state directly, the <c>ContainsKey</c>
/// guards at the marshal sites become advisory and the WM can still hand a
/// freed proxy to libwayland — protocol error, connection drop, greeter.
/// </para>
///
/// <para>
/// This file adds two pieces of plumbing that close that latent class of bug
/// regardless of whether any current call site needs them:
/// </para>
///
/// <list type="number">
/// <item><description>
/// <see cref="Post"/> — a thread-safe primitive that off-thread callers use
/// to marshal a delegate onto the dispatch thread. Posted work is drained at
/// the top of every <c>Dispatch</c> invocation. (Latency is bounded by the
/// rate of incoming Wayland events; for now that's acceptable because the
/// only callers we expect to add are key/input handlers, which themselves
/// generate Wayland traffic that wakes the loop.)
/// </description></item>
/// <item><description>
/// <see cref="AssertOnDispatchThread"/> — a <see cref="ConditionalAttribute"/>
/// debug-only assertion called from WM-state mutators. It captures the first
/// thread that enters <c>Dispatch</c> and trips if any other thread later
/// reaches a guarded mutator. Removed entirely from Release builds, so it
/// has zero runtime cost in shipped binaries.
/// </description></item>
/// </list>
/// </summary>
internal sealed unsafe partial class RiverWindowManagerClient
{
    private readonly ConcurrentQueue<Action> _postedWork = new();
    private int _dispatchThreadId; // 0 until first Dispatch tick.

    /// <summary>
    /// Schedule <paramref name="work"/> to run on the dispatch thread.
    /// Safe to call from any thread. Exceptions thrown by the delegate are
    /// caught and logged so a buggy continuation can't tear down the pump.
    /// </summary>
    /// <remarks>
    /// Wake-up: posted items are drained at the top of every <c>Dispatch</c>
    /// callback, so latency is bounded by Wayland event arrival. If you need
    /// true async wake-up (e.g. for a daemon socket reader that doesn't
    /// otherwise generate compositor traffic), follow up with an
    /// <c>eventfd</c> added to the pump's <c>poll</c> set and have <c>Post</c>
    /// write one byte. We deliberately don't do that yet — no current caller
    /// needs it and the plumbing is simpler without an extra fd to manage.
    /// </remarks>
    public void Post(Action work)
    {
        if (work == null!)
        {
            return;
        }

        _postedWork.Enqueue(work);
    }

    /// <summary>
    /// Drain pending <see cref="Post"/> work. Called from
    /// <c>ProxyDispatcher.Dispatch</c> on every event so that off-thread
    /// callers see their continuations before the next batch of Wayland
    /// events runs.
    /// </summary>
    private void DrainPostedWork()
    {
        while (_postedWork.TryDequeue(out var work))
        {
            try
            {
                work();
            }
            catch (Exception ex)
            {
                Log("posted work threw: " + ex.Message);
            }
        }
    }

    /// <summary>
    /// Record the current managed thread as the dispatch thread on first
    /// call, no-op afterwards. Used by <see cref="AssertOnDispatchThread"/>.
    /// </summary>
    private void EnsureDispatchThreadCaptured()
    {
        if (_dispatchThreadId == 0)
        {
            Interlocked.CompareExchange(ref _dispatchThreadId, Thread.CurrentThread.ManagedThreadId, 0);
        }
    }

    /// <summary>
    /// Debug-only check that the caller is running on the dispatch thread.
    /// Compiled out of Release builds entirely (via
    /// <see cref="ConditionalAttribute"/>), so call freely from hot WM-state
    /// mutators. If this ever trips, the offending call site needs to be
    /// wrapped in <see cref="Post"/>.
    /// </summary>
    [Conditional("DEBUG")]
    private void AssertOnDispatchThread([System.Runtime.CompilerServices.CallerMemberName] string member = "")
    {
        int captured = _dispatchThreadId;
        if (captured == 0)
        {
            // Not captured yet — nothing has dispatched. Allowed: ctor /
            // pre-pump bootstrap still runs on whatever thread the host
            // chose, and that's fine because nothing else can race it yet.
            return;
        }

        if (Thread.CurrentThread.ManagedThreadId != captured)
        {
            Log($"OFF-THREAD WM mutation in {member}: tid={Thread.CurrentThread.ManagedThreadId} expected={captured}");
            Debug.Fail($"OFF-THREAD WM mutation in {member}");
        }
    }
}
