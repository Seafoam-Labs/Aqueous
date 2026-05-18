using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Aqueous.Features.Compositor.River.Registry;

/// <summary>
/// Thread-safe <see cref="ISeatRegistry"/> implementation. Near-verbatim
/// counterpart to <see cref="OutputRegistry"/> minus the geometry / tag
/// fields, kept as a separate sealed class (rather than generic-ised)
/// so the AOT shape stays trivially obvious.
/// </summary>
internal sealed class SeatRegistry : ISeatRegistry
{
    private readonly ConcurrentDictionary<IntPtr, SeatEntry> _byProxy = new();
    private readonly ConcurrentDictionary<uint, IntPtr> _byWlName = new();
    private readonly ILogger<SeatRegistry> _logger;

    public SeatRegistry() : this(NullLogger<SeatRegistry>.Instance)
    {
    }

    public SeatRegistry(ILogger<SeatRegistry> logger)
    {
        _logger = logger;
    }

    public int Count => _byProxy.Count;

    public ConcurrentDictionary<IntPtr, SeatEntry> Entries => _byProxy;

    public event Action<SeatEntry>? Added;
    public event Action<SeatEntry>? Removed;
    public event Action<SeatEntry>? Changed;

    public IReadOnlyCollection<SeatEntry> Snapshot()
    {
        return _byProxy.Values.ToArray();
    }

    public bool TryGet(IntPtr proxy, out SeatEntry entry)
    {
        return _byProxy.TryGetValue(proxy, out entry!);
    }

    public SeatEntry Track(IntPtr proxy, uint wlSeatName)
    {
        if (_byProxy.TryGetValue(proxy, out var existing))
        {
            return existing;
        }

        var fresh = new SeatEntry { Proxy = proxy, WlSeatName = wlSeatName };
        if (!_byProxy.TryAdd(proxy, fresh))
        {
            return _byProxy[proxy];
        }

        _byWlName[wlSeatName] = proxy;
        _logger.LogDebug(
            "Tracked seat proxy=0x{Proxy:X} wlName={WlName}",
            proxy.ToInt64(),
            wlSeatName);
        Added?.Invoke(fresh);
        return fresh;
    }

    public bool Untrack(IntPtr proxy)
    {
        if (!_byProxy.TryRemove(proxy, out var entry))
        {
            return false;
        }

        _byWlName.TryRemove(entry.WlSeatName, out _);
        _logger.LogDebug(
            "Untracked seat proxy=0x{Proxy:X} wlName={WlName}",
            proxy.ToInt64(),
            entry.WlSeatName);
        Removed?.Invoke(entry);
        return true;
    }

    public bool UntrackByName(uint wlSeatName)
    {
        if (!_byWlName.TryRemove(wlSeatName, out var proxy))
        {
            return false;
        }

        if (!_byProxy.TryRemove(proxy, out var entry))
        {
            _logger.LogInformation(
                "global_remove for wlName={WlName} but proxy=0x{Proxy:X} was already untracked",
                wlSeatName,
                proxy.ToInt64());
            return false;
        }

        Removed?.Invoke(entry);
        return true;
    }

    public void Clear()
    {
        _byProxy.Clear();
        _byWlName.Clear();
    }

    public void NotifyChanged(SeatEntry entry)
    {
        if (!_byProxy.ContainsKey(entry.Proxy))
        {
            return;
        }

        Changed?.Invoke(entry);
    }
}
