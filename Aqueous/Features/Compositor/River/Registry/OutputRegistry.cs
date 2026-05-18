using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Aqueous.Features.Compositor.River.Registry;

/// <summary>
/// Thread-safe <see cref="IOutputRegistry"/> implementation. Maintains a
/// primary <see cref="ConcurrentDictionary{TKey,TValue}"/> keyed on the
/// native <c>river_output_v1*</c> proxy and a secondary index keyed on
/// the <c>wl_registry</c>-advertised name so <c>global_remove</c>
/// resolves in O(1).
/// </summary>
internal sealed class OutputRegistry : IOutputRegistry
{
    private readonly ConcurrentDictionary<IntPtr, OutputEntry> _byProxy = new();
    private readonly ConcurrentDictionary<uint, IntPtr> _byWlName = new();
    private readonly ILogger<OutputRegistry> _logger;

    public OutputRegistry() : this(NullLogger<OutputRegistry>.Instance)
    {
    }

    public OutputRegistry(ILogger<OutputRegistry> logger)
    {
        _logger = logger;
    }

    public int Count => _byProxy.Count;

    public event Action<OutputEntry>? Added;
    public event Action<OutputEntry>? Removed;
    public event Action<OutputEntry>? Changed;

    public IReadOnlyCollection<OutputEntry> Snapshot()
    {
        return _byProxy.Values.ToArray();
    }

    public bool TryGet(IntPtr proxy, out OutputEntry entry)
    {
        return _byProxy.TryGetValue(proxy, out entry!);
    }

    public OutputEntry Track(IntPtr proxy, uint wlOutputName)
    {
        if (_byProxy.TryGetValue(proxy, out var existing))
        {
            return existing;
        }

        var fresh = new OutputEntry { Proxy = proxy, WlOutputName = wlOutputName };
        if (!_byProxy.TryAdd(proxy, fresh))
        {
            return _byProxy[proxy];
        }

        _byWlName[wlOutputName] = proxy;
        _logger.LogDebug(
            "Tracked output proxy=0x{Proxy:X} wlName={WlName}",
            proxy.ToInt64(),
            wlOutputName);
        Added?.Invoke(fresh);
        return fresh;
    }

    public bool Untrack(IntPtr proxy)
    {
        if (!_byProxy.TryRemove(proxy, out var entry))
        {
            return false;
        }

        _byWlName.TryRemove(entry.WlOutputName, out _);
        _logger.LogDebug(
            "Untracked output proxy=0x{Proxy:X} wlName={WlName}",
            proxy.ToInt64(),
            entry.WlOutputName);
        Removed?.Invoke(entry);
        return true;
    }

    public bool UntrackByName(uint wlOutputName)
    {
        if (!_byWlName.TryRemove(wlOutputName, out var proxy))
        {
            return false;
        }

        if (!_byProxy.TryRemove(proxy, out var entry))
        {
            // Secondary index pointed at a proxy that's already gone —
            // an anomaly worth noting but not fatal.
            _logger.LogInformation(
                "global_remove for wlName={WlName} but proxy=0x{Proxy:X} was already untracked",
                wlOutputName,
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

    public void NotifyChanged(OutputEntry entry)
    {
        if (!_byProxy.ContainsKey(entry.Proxy))
        {
            return;
        }

        Changed?.Invoke(entry);
    }
}
