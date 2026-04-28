using System;
using System.Collections.Concurrent;
using System.Collections.Generic;

namespace Aqueous.Features.SnapZones;

/// <summary>
/// Per-output owner of <see cref="SnapZoneLayout"/>s plus the currently
/// active layout index. Read-mostly: parsed once at boot and on each
/// <c>wm.toml</c> reload, queried on every drag-end.
///
/// <para>Lookup falls back to the wildcard output id <c>"*"</c> when no
/// output-specific entry exists. Outputs without any matching entry
/// produce <see cref="ActiveLayoutFor"/> = <c>null</c>, which the
/// controller treats as "snap-zones disabled for this output" — drag-end
/// is a no-op and the dragged window stays where the pointer dropped
/// it. This is the documented opt-in behaviour.</para>
/// </summary>
public sealed class SnapZoneStore
{
    /// <summary>Wildcard output id matching every output.</summary>
    public const string Wildcard = "*";

    // Output name → ordered list of layouts. Keyed by river_output_v1.name
    // (the same string used by [[output]] / PerOutput in the layout
    // config), or "*" for the wildcard fallback.
    private readonly Dictionary<string, IReadOnlyList<SnapZoneLayout>> _layoutsByOutput;

    // Output handle → current layout index. Keyed by IntPtr because the
    // human-readable output name isn't always known on the hot path
    // (the drag-end handler has a window's IntPtr Output and resolves
    // the name lazily). Persistence across reload is cheap: an index
    // out of range is clamped to 0 in ActiveLayoutFor.
    private readonly ConcurrentDictionary<IntPtr, int> _activeIndex = new();

    public SnapZoneStore(IReadOnlyDictionary<string, IReadOnlyList<SnapZoneLayout>> layoutsByOutput)
    {
        _layoutsByOutput = new Dictionary<string, IReadOnlyList<SnapZoneLayout>>(
            layoutsByOutput, StringComparer.Ordinal);
    }

    /// <summary>Empty store — snap-zones disabled everywhere.</summary>
    public static SnapZoneStore Empty { get; } =
        new(new Dictionary<string, IReadOnlyList<SnapZoneLayout>>(StringComparer.Ordinal));

    /// <summary>
    /// All layouts that apply to <paramref name="outputName"/>, in
    /// declaration order. Output-specific entries win over the
    /// wildcard; concatenation is intentionally not done so the user
    /// has full control over which layouts are available per output.
    /// </summary>
    public IReadOnlyList<SnapZoneLayout> LayoutsFor(string? outputName)
    {
        if (outputName != null && _layoutsByOutput.TryGetValue(outputName, out var perOut))
        {
            return perOut;
        }

        if (_layoutsByOutput.TryGetValue(Wildcard, out var wild))
        {
            return wild;
        }

        return Array.Empty<SnapZoneLayout>();
    }

    /// <summary>
    /// Returns the currently-active layout for <paramref name="output"/>,
    /// or <c>null</c> if no layouts apply. Does not throw on stale
    /// indices: a reload that shortened the layout list still produces
    /// a valid layout (clamped to 0).
    /// </summary>
    public SnapZoneLayout? ActiveLayoutFor(IntPtr output, string? outputName)
    {
        var layouts = LayoutsFor(outputName);
        if (layouts.Count == 0)
        {
            return null;
        }

        int idx = _activeIndex.TryGetValue(output, out var i) ? i : 0;
        if (idx < 0 || idx >= layouts.Count)
        {
            idx = 0;
        }

        return layouts[idx];
    }

    /// <summary>
    /// Cycle to the next layout for <paramref name="output"/> (KZones'
    /// next-layout keybind). Wraps around. No-op if &lt; 2 layouts apply.
    /// </summary>
    public void CycleLayout(IntPtr output, string? outputName)
    {
        var layouts = LayoutsFor(outputName);
        if (layouts.Count < 2)
        {
            return;
        }

        _activeIndex.AddOrUpdate(output,
            addValueFactory: _ => 1 % layouts.Count,
            updateValueFactory: (_, cur) => (cur + 1) % layouts.Count);
    }

    /// <summary>True iff there is at least one layout applicable anywhere.</summary>
    public bool IsEmpty => _layoutsByOutput.Count == 0;
}
