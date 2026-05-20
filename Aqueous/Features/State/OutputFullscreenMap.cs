using System;
using System.Collections;
using System.Collections.Concurrent;
using System.Collections.Generic;

namespace Aqueous.Features.State;

/// <summary>
/// DI singleton owning the per-output single-fullscreen-slot dictionary. Wraps a <see
/// cref="ConcurrentDictionary{TKey,TValue}"/> mapping output proxy → currently-fullscreen window
/// handle (or <see cref="IntPtr.Zero"/> if none). the class field now aliases this singleton so
/// all existing consumers (LayoutProposer, WindowEventHandler, WindowStateHostAccessors) keep
/// working unchanged while subsequent §2.x lifts can migrate consumers to inject this type
/// directly.
/// </summary>
internal sealed class OutputFullscreenMap : IEnumerable<KeyValuePair<IntPtr, IntPtr>>
{
    private readonly ConcurrentDictionary<IntPtr, IntPtr> _map = new();

    public IntPtr this[IntPtr output]
    {
        get => _map[output];
        set => _map[output] = value;
    }

    public int Count => _map.Count;

    public bool TryGetValue(IntPtr output, out IntPtr window) => _map.TryGetValue(output, out window);

    public bool TryRemove(IntPtr output, out IntPtr window) => _map.TryRemove(output, out window);

    public IEnumerator<KeyValuePair<IntPtr, IntPtr>> GetEnumerator() => _map.GetEnumerator();

    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();
}
