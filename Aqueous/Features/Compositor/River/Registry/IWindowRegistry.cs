using System;
using System.Collections.Concurrent;
using System.Collections.Generic;

namespace Aqueous.Features.Compositor.River.Registry;

/// <summary>
/// Owns the dictionary of long-lived <see cref="WindowEntry"/> instances keyed by their native
/// <c>river_window_v1*</c> proxy.
/// </summary>
/// <remarks>
/// <para>
/// Lifetime is <c>Singleton</c>. This service is <i>not</i> an <c>IHostedService</c>; its
/// lifecycle is driven entirely by River events (<c>river_window_manager_v1::window</c> → <see
/// cref="Track"/>, <c>river_window_v1::closed</c> → <see cref="Untrack"/>).
/// </para>
/// <para>
/// <b>Threading contract:</b> <see cref="Track"/>, <see cref="Untrack"/>, <see cref="Clear"/> and
/// <see cref="NotifyChanged"/> must be called from the pump thread only. <see cref="Snapshot"/>,
/// <see cref="TryGet"/> and <see cref="Count"/> are thread-safe. Event handlers run on the pump
/// thread; subscribers that touch Avalonia must marshal to the UI thread themselves.
/// </para>
/// </remarks>
internal interface IWindowRegistry
{
    /// <summary>
    /// Snapshot of all currently-tracked windows. Safe to enumerate from any thread; the returned
    /// collection is a point-in-time copy and does not reflect later mutations.
    /// </summary>
    IReadOnlyCollection<WindowEntry> Snapshot();

    /// <summary>
    /// Number of tracked windows. O(1).
    /// </summary>
    int Count { get; }

    /// <summary>
    /// Look up an entry by its native <c>river_window_v1*</c> proxy.
    /// </summary>
    bool TryGet(IntPtr proxy, out WindowEntry entry);

    /// <summary>
    /// Register a freshly-bound window proxy. Called by the event handler that receives
    /// <c>river_window_manager_v1::window</c>. Idempotent: re-tracking an existing proxy returns the
    /// existing entry without raising <see cref="Added"/> a second time.
    /// </summary>
    WindowEntry Track(IntPtr proxy);

    /// <summary>
    /// Drop a window in response to <c>river_window_v1::closed</c> (or compositor teardown). Raises
    /// <see cref="Removed"/> when the proxy was tracked; no-op otherwise.
    /// </summary>
    /// <returns>
    /// <c>true</c> when the proxy was tracked and the entry has been dropped;
    /// <c>false</c> if the proxy was unknown.
    /// </returns>
    bool Untrack(IntPtr proxy);

    /// <summary>
    /// Drop every entry without raising <see cref="Removed"/>. Used only by the compositor host's
    /// <c>StopAsync</c> after the event pump has stopped.
    /// </summary>
    void Clear();

    /// <summary>
    /// Raised after <see cref="Track"/> creates a new entry.
    /// </summary>
    event Action<WindowEntry>? Added;

    /// <summary>
    /// Raised after <see cref="Untrack"/> removes an entry.
    /// </summary>
    event Action<WindowEntry>? Removed;

    /// <summary>
    /// Raised by <see cref="NotifyChanged"/>. Subscribers should treat this as a "dirty" tick, not a
    /// diff — the entry itself carries the new state. Expect dozens of fires per second during drag /
    /// resize storms, so handlers must be cheap or coalesce.
    /// </summary>
    event Action<WindowEntry>? Changed;

    /// <summary>
    /// Mark an entry dirty and raise <see cref="Changed"/>. Callers (River event handlers) must have
    /// already mutated the entry's fields before invoking this method.
    /// </summary>
    void NotifyChanged(WindowEntry entry);

    /// <summary>
    /// Direct access to the backing <see cref="ConcurrentDictionary{TKey,TValue}"/>. Provided as
    /// an escape hatch for callers that need to iterate <c>.Keys</c>, call <c>TryRemove</c>, or
    /// index by proxy. Prefer <see cref="Track"/>, <see cref="Untrack"/>, <see cref="TryGet"/>
    /// or <see cref="Snapshot"/> where they suffice.
    /// </summary>
    ConcurrentDictionary<IntPtr, WindowEntry> Entries { get; }
}
