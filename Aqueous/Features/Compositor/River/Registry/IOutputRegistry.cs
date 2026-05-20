using System;
using System.Collections.Concurrent;
using System.Collections.Generic;

namespace Aqueous.Features.Compositor.River.Registry;

/// <summary>
/// Owns the dictionary of long-lived <see cref="OutputEntry"/> instances keyed by their native
/// <c>river_output_v1*</c> proxy, with a secondary <c>wl_registry</c>-name index so
/// <c>wl_registry::global_remove</c> events can resolve to a proxy without a linear scan.
/// </summary>
/// <remarks>
/// <para>
/// Lifetime is <c>Singleton</c>. This service is <i>not</i> an <c>IHostedService</c>; its
/// lifecycle is driven by <c>wl_registry::global</c> / <c>global_remove</c> and
/// <c>river_output_v1::finished</c>.
/// </para>
/// <para>
/// <b>Threading contract:</b> <see cref="Track"/>, <see cref="Untrack"/>, <see
/// cref="UntrackByName"/>, <see cref="Clear"/> and <see cref="NotifyChanged"/> must be called from
/// the pump thread only. <see cref="Snapshot"/>, <see cref="TryGet"/> and <see cref="Count"/> are
/// thread-safe.
/// </para>
/// <para>
/// Per-output tag state on <see cref="OutputEntry"/> (<c>VisibleTags</c>, <c>LastVisibleTags</c>,
/// <c>TagHistory</c>) is owned by <c>TagController</c>; this registry only stores entries and
/// never mutates those fields.
/// </para>
/// </remarks>
internal interface IOutputRegistry
{
    /// <summary>
    /// Snapshot of all currently-tracked outputs. Safe to enumerate from any thread; the returned
    /// collection is a point-in-time copy.
    /// </summary>
    IReadOnlyCollection<OutputEntry> Snapshot();

    /// <summary>
    /// Number of tracked outputs. O(1).
    /// </summary>
    int Count { get; }

    /// <summary>
    /// Look up an entry by its native <c>river_output_v1*</c> proxy.
    /// </summary>
    bool TryGet(IntPtr proxy, out OutputEntry entry);

    /// <summary>
    /// Register a freshly-bound output proxy and remember its <c>wl_registry</c> name so <see
    /// cref="UntrackByName"/> can find it later. Idempotent.
    /// </summary>
    /// <param name="proxy">
    /// The native <c>river_output_v1*</c>.
    /// </param>
    /// <param name="wlOutputName">
    /// The registry name advertised by <c>wl_registry::global</c>. Stored on the entry as <see
    /// cref="OutputEntry.WlOutputName"/>.
    /// </param>
    OutputEntry Track(IntPtr proxy, uint wlOutputName);

    /// <summary>
    /// Drop an output by proxy. Used by the <c>river_output_v1::finished</c> handler. Raises <see
    /// cref="Removed"/> when the proxy was tracked.
    /// </summary>
    bool Untrack(IntPtr proxy);

    /// <summary>
    /// Drop an output by its <c>wl_registry</c> name. Used by the <c>wl_registry::global_remove</c>
    /// handler. Raises <see cref="Removed"/> when the name was tracked.
    /// </summary>
    bool UntrackByName(uint wlOutputName);

    /// <summary>
    /// Drop every entry without raising <see cref="Removed"/>. Used only by the compositor host's
    /// <c>StopAsync</c> after the event pump has stopped.
    /// </summary>
    void Clear();

    /// <summary>
    /// Raised after <see cref="Track"/> creates a new entry.
    /// </summary>
    event Action<OutputEntry>? Added;

    /// <summary>
    /// Raised after an entry is removed by proxy or by name.
    /// </summary>
    event Action<OutputEntry>? Removed;

    /// <summary>
    /// Raised by <see cref="NotifyChanged"/>.
    /// </summary>
    event Action<OutputEntry>? Changed;

    /// <summary>
    /// Mark an entry dirty and raise <see cref="Changed"/>. Callers (e.g. geometry / mode event
    /// handlers) must have already mutated the entry's fields before invoking this method.
    /// </summary>
    void NotifyChanged(OutputEntry entry);

    /// <summary>
    /// Direct access to the backing <see cref="ConcurrentDictionary{TKey,TValue}"/>. Exposed so
    /// partials of <see cref="RiverWindowManagerClient"/> can continue to compile. New code should use
    /// <see cref="Track"/> / <see cref="Untrack"/> / <see cref="TryGet"/> / <see cref="Snapshot"/>
    /// instead.
    /// </summary>
    ConcurrentDictionary<IntPtr, OutputEntry> Entries { get; }
}
