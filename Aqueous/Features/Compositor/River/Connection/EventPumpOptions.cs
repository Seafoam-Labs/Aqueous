using System;

namespace Aqueous.Features.Compositor.River.Connection;

/// <summary>
/// Options controlling the <see cref="IEventPump"/> background thread. Designed to be bound from
/// configuration (<c>builder.Services.Configure&lt;EventPumpOptions&gt;</c>) once the host moves
/// to <c>Microsoft.Extensions.Hosting</c>; defaults are sensible without any configuration.
/// </summary>
public sealed class EventPumpOptions
{
    /// <summary>
    /// Name applied to the pump thread (visible in <c>gdb</c>, <c>perf</c>, <c>top -H</c>). Defaults
    /// to <c>"Aqueous.RiverWindowManager"</c>.
    /// </summary>
    public string ThreadName { get; init; } = "Aqueous.RiverWindowManager";

    /// <summary>
    /// Default join timeout used by <see cref="IDisposable.Dispose"/> when no explicit timeout is
    /// provided. Defaults to 500&#160;ms.
    /// </summary>
    public TimeSpan DefaultJoinTimeout { get; init; } = TimeSpan.FromMilliseconds(500);

    /// <summary>
    /// If true, every <c>wl_display_dispatch</c> return code is logged at <c>Trace</c> level. Off by
    /// default; useful for diagnosing event-starvation bugs.
    /// </summary>
    public bool VerboseDispatchTrace { get; init; }

    /// <summary>
    /// Invoked once on the pump thread immediately before the dispatch loop starts. Used by
    /// <c>IManagerRequestSender</c> to record the pump thread id so off-pump callers route their
    /// marshal calls through <see cref="OnDispatchIteration"/>.
    /// </summary>
    public Action? OnPumpThreadStart { get; init; }

    /// <summary>
    /// Invoked on the pump thread once per dispatch iteration, after <c>wl_display_dispatch</c>
    /// returns. Used to drain queued pump-thread actions (e.g. <c>manage_dirty</c> hints posted
    /// from off-pump callers). MUST be cheap and non-throwing.
    /// </summary>
    public Action? OnDispatchIteration { get; init; }

    /// <summary>
    /// Invoked once on the pump thread just before it exits (after <c>OnPumpThreadStart</c> has
    /// fired). Lets consumers clear any "we are on the pump thread" affinity state.
    /// </summary>
    public Action? OnPumpThreadStop { get; init; }
}
