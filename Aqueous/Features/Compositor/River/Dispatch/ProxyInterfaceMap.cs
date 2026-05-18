using System;
using System.Collections.Generic;

namespace Aqueous.Features.Compositor.River.Dispatch;

/// <summary>
/// Stage 0 of the <c>RiverWindowManagerClient</c> decomposition: a tiny,
/// single-threaded <c>IntPtr → Wayland interface name</c> map that is
/// populated at every proxy-bind site and read by the native dispatcher
/// in Stage 8 to construct <see cref="WlEvent.InterfaceName"/>.
///
/// Stage 0 is intentionally write-only from the dispatcher's perspective:
/// the existing <c>if/else</c> chain in <c>ProxyDispatcher.Dispatch</c>
/// continues to route by raw <see cref="IntPtr"/> identity, so missed or
/// extra entries in this map cannot currently break dispatch. Once the
/// callback is rewritten to delegate to <c>IEventDispatcher</c> (Stage 8),
/// every routed proxy must have been tracked through
/// <see cref="Track"/> at bind time.
///
/// Threading: not thread-safe. Every populating site runs either on the
/// connect thread (registry binds) or the pump thread (handler-driven
/// binds), never both concurrently — matching the rest of
/// <c>RiverWindowManagerClient</c>'s single-threaded model.
/// </summary>
internal sealed class ProxyInterfaceMap
{
    private readonly Dictionary<IntPtr, string> _map = new();

    /// <summary>
    /// Record the Wayland interface name of a freshly bound proxy.
    /// Tolerant of <see cref="IntPtr.Zero"/> and null/empty names
    /// (silent no-op) so call sites can invoke immediately after
    /// <c>wl_proxy_marshal_flags</c> without an inline null check.
    /// Re-tracking the same proxy with a different name is treated as
    /// a programmer error — returns <c>false</c> and preserves the
    /// original mapping.
    /// </summary>
    /// <returns>
    /// <c>true</c> if the call resulted in a new entry being added.
    /// </returns>
    public bool Track(IntPtr proxy, string? interfaceName)
    {
        if (proxy == IntPtr.Zero || string.IsNullOrEmpty(interfaceName))
        {
            return false;
        }
        if (_map.TryGetValue(proxy, out _))
        {
            return false;
        }
        _map[proxy] = interfaceName;
        return true;
    }

    /// <summary>Remove a proxy mapping; no-op when absent.</summary>
    public bool Untrack(IntPtr proxy) => _map.Remove(proxy);

    /// <summary>Look up the interface name for a proxy.</summary>
    public string? TryGet(IntPtr proxy) =>
        _map.TryGetValue(proxy, out var name) ? name : null;

    /// <summary>Number of currently tracked proxies.</summary>
    public int Count => _map.Count;
}
