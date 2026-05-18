using System;

namespace Aqueous.Features.Compositor.River.Connection;

/// <summary>
/// Options controlling the <see cref="IEventPump"/> background thread.
/// Designed to be bound from configuration
/// (<c>builder.Services.Configure&lt;EventPumpOptions&gt;</c>) once
/// the host moves to <c>Microsoft.Extensions.Hosting</c>; defaults
/// are sensible without any configuration.
/// </summary>
public sealed class EventPumpOptions
{
    /// <summary>
    /// Name applied to the pump thread (visible in <c>gdb</c>,
    /// <c>perf</c>, <c>top -H</c>). Defaults to
    /// <c>"Aqueous.RiverWindowManager"</c>.
    /// </summary>
    public string ThreadName { get; init; } = "Aqueous.RiverWindowManager";

    /// <summary>
    /// Default join timeout used by <see cref="IDisposable.Dispose"/>
    /// when no explicit timeout is provided. Defaults to 500&#160;ms.
    /// </summary>
    public TimeSpan DefaultJoinTimeout { get; init; } = TimeSpan.FromMilliseconds(500);

    /// <summary>
    /// If true, every <c>wl_display_dispatch</c> return code is
    /// logged at <c>Trace</c> level. Off by default; useful for
    /// diagnosing event-starvation bugs.
    /// </summary>
    public bool VerboseDispatchTrace { get; init; }
}
