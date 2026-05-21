using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using Aqueous.Features.Layout;

namespace Aqueous.Features.SnapZones;

/// <summary>
/// Per-output owner of <see cref="SnapZoneLayout"/>s plus the currently active layout index.
/// Read-mostly: parsed once at boot and on each <c>wm.toml</c> reload, queried on every drag-end.
/// <para>
/// Lookup falls back to the wildcard output id <c>"*"</c> when no output-specific entry exists.
/// Outputs without any matching entry produce <see cref="ActiveLayoutFor"/> = <c>null</c>, which
/// the controller treats as "snap-zones disabled for this output" — drag-end is a no-op and the
/// dragged window stays where the pointer dropped it. This is the documented opt-in behaviour.
/// </para>
/// </summary>
public sealed class SnapZoneStore
{
    /// <summary>
    /// Wildcard output id matching every output.
    /// </summary>
    public const string Wildcard = "*";

    // Output name → ordered list of layouts. Keyed by river_output_v1.name (the same string used by
    // [[output]] / PerOutput in the layout config), or "*" for the wildcard fallback.
    private readonly Dictionary<string, IReadOnlyList<SnapZoneLayout>> _layoutsByOutput;

    // EDID/make/model/serial-keyed buckets, populated when a [[snapzones]] block selects its target
    // via `edid =`/`make =`/`model =`/`serial =` instead of a connector `output =` name. Searched in
    // declaration order after the name-keyed dictionary, before the "*" wildcard.
    private readonly IReadOnlyList<(OutputSelector Selector, IReadOnlyList<SnapZoneLayout> Layouts)>
        _layoutsBySelector;

    // Output handle → current layout index. Keyed by IntPtr because the human-readable output name
    // isn't always known on the hot path (the drag-end handler has a window's IntPtr Output and
    // resolves the name lazily). Persistence across reload is cheap: an index out of range is clamped
    // to 0 in ActiveLayoutFor.
    private readonly ConcurrentDictionary<IntPtr, int> _activeIndex = new();

    public SnapZoneStore(IReadOnlyDictionary<string, IReadOnlyList<SnapZoneLayout>> layoutsByOutput)
        : this(layoutsByOutput, Array.Empty<(OutputSelector, IReadOnlyList<SnapZoneLayout>)>())
    {
    }

    /// <summary>
    /// Construct a store with both connector-name and EDID/make/model/serial selector buckets.
    /// Lookups try the name dictionary first, then walk the selector list in declaration order, then
    /// fall back to the <c>"*"</c> wildcard bucket if any.
    /// </summary>
    public SnapZoneStore(
        IReadOnlyDictionary<string, IReadOnlyList<SnapZoneLayout>> layoutsByOutput,
        IReadOnlyList<(OutputSelector Selector, IReadOnlyList<SnapZoneLayout> Layouts)> layoutsBySelector)
    {
        _layoutsByOutput = new Dictionary<string, IReadOnlyList<SnapZoneLayout>>(
            layoutsByOutput, StringComparer.Ordinal);
        _layoutsBySelector = layoutsBySelector
            ?? Array.Empty<(OutputSelector, IReadOnlyList<SnapZoneLayout>)>();
    }

    /// <summary>
    /// Empty store — snap-zones disabled everywhere.
    /// </summary>
    public static SnapZoneStore Empty { get; } =
        new(new Dictionary<string, IReadOnlyList<SnapZoneLayout>>(StringComparer.Ordinal));

    /// <summary>
    /// All layouts that apply to <paramref name="outputName"/>, in declaration order. Output-specific
    /// entries win over the wildcard; concatenation is intentionally not done so the user has full
    /// control over which layouts are available per output.
    /// </summary>
    public IReadOnlyList<SnapZoneLayout> LayoutsFor(string? outputName)
        => LayoutsFor(outputName, edidSha256: null, make: null, model: null, serial: null);

    /// <summary>
    /// Selector-aware overload: tries the connector-name bucket first, then the EDID/make/model/
    /// serial selector list in declaration order, finally the <c>"*"</c> wildcard.
    /// </summary>
    public IReadOnlyList<SnapZoneLayout> LayoutsFor(
        string? outputName,
        string? edidSha256,
        string? make,
        string? model,
        string? serial)
    {
        if (outputName != null && _layoutsByOutput.TryGetValue(outputName, out var perOut))
        {
            return perOut;
        }

        for (int i = 0; i < _layoutsBySelector.Count; i++)
        {
            var (sel, layouts) = _layoutsBySelector[i];
            if (sel.Matches(outputName, edidSha256, make, model, serial))
            {
                return layouts;
            }
        }

        if (_layoutsByOutput.TryGetValue(Wildcard, out var wild))
        {
            return wild;
        }

        return Array.Empty<SnapZoneLayout>();
    }

    /// <summary>
    /// Returns the currently-active layout for <paramref name="output"/>, or <c>null</c> if no layouts
    /// apply. Does not throw on stale indices: a reload that shortened the layout list still produces
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
    /// Cycle to the next layout for <paramref name="output"/> (KZones' next-layout keybind). Wraps
    /// around. No-op if &lt; 2 layouts apply.
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

    /// <summary>
    /// True iff there is at least one layout applicable anywhere.
    /// </summary>
    public bool IsEmpty => _layoutsByOutput.Count == 0 && _layoutsBySelector.Count == 0;
}
