using System;
using System.Collections;
using System.Collections.Concurrent;
using System.Collections.Generic;

namespace Aqueous.Features.State;

/// <summary>
/// DI singleton owning the per-window state projection (FS / Max / Float / Min / Scratchpad).
/// Wraps a <see cref="ConcurrentDictionary{TKey,TValue}"/> keyed by window proxy handle. the class
/// field now aliases this singleton so all existing consumers (WindowEventHandler,
/// ManagerEventHandler, LayoutProposer, WindowStateHostAccessors) keep working unchanged while
/// subsequent §2.x lifts can migrate consumers to inject this type directly.
/// </summary>
internal sealed class WindowStateStore : IEnumerable<KeyValuePair<IntPtr, WindowStateData>>
{
    private readonly ConcurrentDictionary<IntPtr, WindowStateData> _map = new();

    public int Count => _map.Count;

    public bool TryGetValue(IntPtr handle, out WindowStateData? state) => _map.TryGetValue(handle, out state);

    public bool TryRemove(IntPtr handle, out WindowStateData? state) => _map.TryRemove(handle, out state);

    public WindowStateData GetOrAdd(IntPtr handle, Func<IntPtr, WindowStateData> factory) =>
        _map.GetOrAdd(handle, factory);

    public IEnumerator<KeyValuePair<IntPtr, WindowStateData>> GetEnumerator() => _map.GetEnumerator();

    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();

    /// <summary>
    /// Returns a snapshot list of all tracked window states. Replaces
    /// <c>RiverWindowManagerClient.SnapshotWindowStates()</c>; the class method now delegates here.
    /// </summary>
    public IReadOnlyList<WindowStateData> Snapshot()
    {
        var list = new List<WindowStateData>(_map.Count);
        foreach (var kv in _map)
        {
            list.Add(kv.Value);
        }
        return list;
    }
}
