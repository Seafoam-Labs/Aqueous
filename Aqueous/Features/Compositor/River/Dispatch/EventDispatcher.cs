using System;
using System.Collections.Frozen;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Threading;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Aqueous.Features.Compositor.River.Dispatch;

/// <summary>
/// Default <see cref="IEventDispatcher"/> implementation backed by a
/// <see cref="FrozenDictionary{TKey,TValue}"/> built once at construction
/// from the injected handlers — AOT-friendly, allocation-free on the hot
/// path, no reflection.
///
/// Duplicate-interface guard: registering two handlers for the same
/// <see cref="IEventHandler.InterfaceName"/> throws
/// <see cref="InvalidOperationException"/> from the constructor. Since
/// handlers are registered explicitly in <c>Program.cs</c> (no assembly
/// scanning), this is a cheap fail-fast for programmer mistakes.
///
/// Pump-thread affinity: in <c>DEBUG</c> builds, the first call to
/// <see cref="Dispatch"/> captures the calling thread; subsequent calls
/// assert they originate from that same thread. Release builds elide
/// the check entirely.
/// </summary>
internal sealed class EventDispatcher : IEventDispatcher
{
    private readonly FrozenDictionary<string, IEventHandler> _table;
    private readonly ILogger<EventDispatcher> _log;

#if DEBUG
    private int _pumpThreadId;
#endif

    public EventDispatcher(IEnumerable<IEventHandler> handlers)
        : this(handlers, NullLogger<EventDispatcher>.Instance)
    {
    }

    public EventDispatcher(IEnumerable<IEventHandler> handlers, ILogger<EventDispatcher> log)
    {
        ArgumentNullException.ThrowIfNull(handlers);
        ArgumentNullException.ThrowIfNull(log);

        _log = log;

        // Materialise once so we can scan for duplicates with a stable
        // ordering. The handlers IEnumerable is documented to be the
        // DI container's resolution of IEnumerable<IEventHandler>, but
        // we don't want to enumerate it twice.
        var list = handlers as IReadOnlyList<IEventHandler> ?? handlers.ToArray();

        var seen = new Dictionary<string, IEventHandler>(StringComparer.Ordinal);
        foreach (var h in list)
        {
            if (h is null)
            {
                throw new ArgumentException("Null IEventHandler in registration list.", nameof(handlers));
            }
            if (string.IsNullOrEmpty(h.InterfaceName))
            {
                throw new ArgumentException(
                    $"IEventHandler of type '{h.GetType().FullName}' returned a null or empty InterfaceName.",
                    nameof(handlers));
            }
            if (seen.TryGetValue(h.InterfaceName, out var existing))
            {
                throw new InvalidOperationException(
                    $"Duplicate IEventHandler registration for interface '{h.InterfaceName}': " +
                    $"'{existing.GetType().FullName}' and '{h.GetType().FullName}'.");
            }
            seen.Add(h.InterfaceName, h);
        }

        _table = seen.ToFrozenDictionary(StringComparer.Ordinal);
    }

    /// <summary>Number of registered handlers. Useful for tests.</summary>
    internal int HandlerCount => _table.Count;

    public void Dispatch(WlEvent ev)
    {
        AssertPumpThread();

        if (_table.TryGetValue(ev.InterfaceName, out var handler))
        {
            handler.Handle(ev);
        }
        else
        {
            // Unknown interface — expected for globals we don't bind.
            // Trace, do not throw, do not log at warn (would be noisy).
            if (_log.IsEnabled(LogLevel.Trace))
            {
                _log.LogTrace("Unhandled event for {Interface} opcode {Opcode}",
                    ev.InterfaceName, ev.Opcode);
            }
        }
    }

    [Conditional("DEBUG")]
    private void AssertPumpThread()
    {
#if DEBUG
        var current = Environment.CurrentManagedThreadId;
        var captured = Interlocked.CompareExchange(ref _pumpThreadId, current, 0);
        if (captured != 0 && captured != current)
        {
            throw new InvalidOperationException(
                $"EventDispatcher.Dispatch called on thread {current} but is " +
                $"pinned to pump thread {captured}.");
        }
#endif
    }
}
