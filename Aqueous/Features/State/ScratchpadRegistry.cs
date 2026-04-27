using System;
using System.Collections.Generic;

namespace Aqueous.Features.State;

/// <summary>
/// Phase B1e — named scratchpad slots. Each slot holds at most one window
/// handle (or <c>null</c> when the pad is empty). Slots are created on
/// first use; the <c>"default"</c> slot is implied. Look-ups and writes
/// are case-sensitive ordinal because pad names appear in <c>wm.toml</c>
/// and on the IPC wire (B1g).
/// </summary>
public sealed class ScratchpadRegistry
{
    /// <summary>Conventional name of the default pad bound to <c>Super+\</c>.</summary>
    public const string DefaultPad = "default";

    private readonly Dictionary<string, IntPtr> _pads =
        new(StringComparer.Ordinal);

    /// <summary>Snapshot of currently-occupied pad names (for diagnostics / IPC).</summary>
    public IReadOnlyDictionary<string, IntPtr> Pads => _pads;

    /// <summary>Returns the window currently parked in <paramref name="name"/>, or <see cref="IntPtr.Zero"/>.</summary>
    public IntPtr Get(string name) =>
        _pads.TryGetValue(name, out var w) ? w : IntPtr.Zero;

    /// <summary>True iff <paramref name="name"/> currently holds a window.</summary>
    public bool IsOccupied(string name) =>
        _pads.TryGetValue(name, out var w) && w != IntPtr.Zero;

    /// <summary>
    /// Assigns <paramref name="window"/> to <paramref name="name"/>, evicting
    /// any prior occupant. Returns the prior occupant (or <see cref="IntPtr.Zero"/>)
    /// so the controller can demote that window back to <c>Tiled</c>.
    /// </summary>
    public IntPtr Assign(string name, IntPtr window)
    {
        var prior = Get(name);
        _pads[name] = window;
        return prior;
    }

    /// <summary>Removes <paramref name="window"/> from whichever pad owns it. Returns the pad name or <c>null</c>.</summary>
    public string? Forget(IntPtr window)
    {
        string? hit = null;
        foreach (var kv in _pads)
        {
            if (kv.Value == window) { hit = kv.Key; break; }
        }
        if (hit != null)
        {
            _pads.Remove(hit);
        }

        return hit;
    }

    /// <summary>Clears the named slot regardless of occupant.</summary>
    public void Clear(string name) => _pads.Remove(name);
}
