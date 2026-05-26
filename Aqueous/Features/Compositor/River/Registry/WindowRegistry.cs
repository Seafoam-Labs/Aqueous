using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Aqueous.Features.Compositor.River.Registry;

/// <summary>
/// Thread-safe <see cref="IWindowRegistry"/> implementation backed by a single <see
/// cref="ConcurrentDictionary{TKey,TValue}"/> keyed on the native <c>river_window_v1*</c> proxy.
/// </summary>
/// <remarks>
/// Mutators must run on the pump thread (see <see cref="IWindowRegistry"/>); only the reader
/// surface (<see cref="Snapshot"/>, <see cref="TryGet"/>, <see cref="Count"/>) is safe from
/// arbitrary threads.
/// </remarks>
internal sealed class WindowRegistry : IWindowRegistry
{
    private readonly ConcurrentDictionary<IntPtr, WindowEntry> _byProxy = new();
    private readonly ILogger<WindowRegistry> _logger;

    public WindowRegistry() : this(NullLogger<WindowRegistry>.Instance)
    {
    }

    public WindowRegistry(ILogger<WindowRegistry> logger)
    {
        _logger = logger;
    }

    public int Count => _byProxy.Count;

    public ConcurrentDictionary<IntPtr, WindowEntry> Entries => _byProxy;

    public event Action<WindowEntry>? Added;
    public event Action<WindowEntry>? Removed;
    public event Action<WindowEntry>? Changed;

    public IReadOnlyCollection<WindowEntry> Snapshot()
    {
        // Explicit ToArray rather than yield: keeps AOT shape obvious and avoids state-machine boxing on
        // the layout hot path.
        return _byProxy.Values.ToArray();
    }

    public bool TryGet(IntPtr proxy, out WindowEntry entry)
    {
        return _byProxy.TryGetValue(proxy, out entry!);
    }

    public WindowEntry Track(IntPtr proxy)
    {
        // Idempotent: if a window event arrives twice for the same proxy, return the existing entry
        // without raising Added again.
        if (_byProxy.TryGetValue(proxy, out var existing))
        {
            return existing;
        }

        var fresh = new WindowEntry { Proxy = proxy };
        if (!_byProxy.TryAdd(proxy, fresh))
        {
            // Lost the race with a concurrent Track; return the winner.
            return _byProxy[proxy];
        }

        _logger.LogDebug("Tracked window proxy=0x{Proxy:X}", proxy.ToInt64());
        Added?.Invoke(fresh);
        return fresh;
    }

    public bool Untrack(IntPtr proxy)
    {
        if (!_byProxy.TryRemove(proxy, out var entry))
        {
            return false;
        }

        _logger.LogDebug("Untracked window proxy=0x{Proxy:X}", proxy.ToInt64());
        Removed?.Invoke(entry);
        // Null the native handle on the entry after removal so any stale reference held by an
        // in-flight layout/dispatch pass observes a zero proxy and short-circuits before calling
        // into libwayland (see liveness gate in LayoutProposer's hide-pass). Mirrors the
        // ManagerRequestSender.Reset() pattern: the field is the single source of truth for
        // "this proxy is gone".
        entry.Proxy = IntPtr.Zero;
        // Clear ShowSent so a future re-Track of a freshly-allocated proxy at the same address
        // starts from the "never shown" state and the hide-pass liveness gate in LayoutProposer
        // correctly skips it until we've emitted dimensions(opcode 3) again.
        entry.ShowSent = false;
        return true;
    }

    public void Clear()
    {
        _byProxy.Clear();
    }

    public void NotifyChanged(WindowEntry entry)
    {
        // Only raise for entries we actually own; silently drop stray notifications so a stale handler
        // can't fan-out a phantom event.
        if (!_byProxy.ContainsKey(entry.Proxy))
        {
            return;
        }

        Changed?.Invoke(entry);
    }
}
