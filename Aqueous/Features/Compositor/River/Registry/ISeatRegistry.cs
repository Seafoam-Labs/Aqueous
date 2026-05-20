using System;
using System.Collections.Concurrent;
using System.Collections.Generic;

namespace Aqueous.Features.Compositor.River.Registry;

/// <summary>
/// Owns the dictionary of long-lived <see cref="SeatEntry"/> instances keyed by their native
/// <c>river_seat_v1*</c> proxy, with a secondary <c>wl_registry</c>-name index so
/// <c>wl_registry::global_remove</c> events can resolve to a proxy without a linear scan.
/// </summary>
/// <remarks>
/// <para>
/// Lifetime is <c>Singleton</c>. This service is <i>not</i> an <c>IHostedService</c>; its
/// lifecycle is driven by <c>wl_registry::global</c> / <c>global_remove</c>.
/// </para>
/// <para>
/// <b>Threading contract:</b> <see cref="Track"/>, <see cref="Untrack"/>, <see
/// cref="UntrackByName"/>, <see cref="Clear"/> and <see cref="NotifyChanged"/> must be called from
/// the pump thread only. <see cref="Snapshot"/>, <see cref="TryGet"/> and <see cref="Count"/> are
/// thread-safe.
/// </para>
/// <para>
/// Expected <see cref="Count"/> is <c>1</c> on the vast majority of setups; no read/lookup
/// optimisation is warranted.
/// </para>
/// </remarks>
internal interface ISeatRegistry
{
    /// <summary>
    /// Snapshot of all currently-tracked seats. Safe to enumerate from any thread; the returned
    /// collection is a point-in-time copy.
    /// </summary>
    IReadOnlyCollection<SeatEntry> Snapshot();

    /// <summary>
    /// Number of tracked seats. O(1).
    /// </summary>
    int Count { get; }

    /// <summary>
    /// Look up an entry by its native <c>river_seat_v1*</c> proxy.
    /// </summary>
    bool TryGet(IntPtr proxy, out SeatEntry entry);

    /// <summary>
    /// Register a freshly-bound seat proxy and remember its <c>wl_registry</c> name so <see
    /// cref="UntrackByName"/> can find it later. Idempotent.
    /// </summary>
    /// <param name="proxy">
    /// The native <c>river_seat_v1*</c>.
    /// </param>
    /// <param name="wlSeatName">
    /// The registry name advertised by <c>wl_registry::global</c>. Stored on the entry as <see
    /// cref="SeatEntry.WlSeatName"/>.
    /// </param>
    SeatEntry Track(IntPtr proxy, uint wlSeatName);

    /// <summary>
    /// Drop a seat by proxy.
    /// </summary>
    bool Untrack(IntPtr proxy);

    /// <summary>
    /// Drop a seat by its <c>wl_registry</c> name.
    /// </summary>
    bool UntrackByName(uint wlSeatName);

    /// <summary>
    /// Drop every entry without raising <see cref="Removed"/>. Used only by the compositor host's
    /// <c>StopAsync</c> after the event pump has stopped.
    /// </summary>
    void Clear();

    /// <summary>
    /// Raised after <see cref="Track"/> creates a new entry.
    /// </summary>
    event Action<SeatEntry>? Added;

    /// <summary>
    /// Raised after an entry is removed by proxy or by name.
    /// </summary>
    event Action<SeatEntry>? Removed;

    /// <summary>
    /// Raised by <see cref="NotifyChanged"/>.
    /// </summary>
    event Action<SeatEntry>? Changed;

    /// <summary>
    /// Mark an entry dirty and raise <see cref="Changed"/>.
    /// </summary>
    void NotifyChanged(SeatEntry entry);

    /// <summary>
    /// Direct access to the backing <see cref="ConcurrentDictionary{TKey,TValue}"/>. Exposed so
    /// partials of <see cref="RiverWindowManagerClient"/> can continue to compile. New code should use
    /// <see cref="Track"/> / <see cref="Untrack"/> / <see cref="TryGet"/> / <see cref="Snapshot"/>
    /// instead.
    /// </summary>
    ConcurrentDictionary<IntPtr, SeatEntry> Entries { get; }
}
