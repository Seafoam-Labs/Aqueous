using System.Collections.Generic;
using System.Runtime.CompilerServices;
using Aqueous.Features.Input;
using Aqueous.Features.SnapZones;
using Aqueous.Features.State;

[assembly: InternalsVisibleTo("Aqueous.Tests")]

namespace Aqueous.Features.Layout;

/// <summary>
/// In-memory representation of <c>~/.config/aqueous/wm.toml</c>. Only the
/// keys actually consumed by the layout subsystem are modelled. Parsing
/// lives in <see cref="LayoutConfigLoader"/> — this file is the model and
/// defaults only.
/// </summary>
public sealed class LayoutConfig
{
    /// <summary>Global default layout id (used when nothing else applies).</summary>
    public string DefaultLayout { get; init; } = "tile";

    public InputConfig Input { get; init; } = InputConfig.Default;

    /// <summary>Default options applied to every layout that doesn't override them.</summary>
    public LayoutOptions Defaults { get; init; } = LayoutOptions.Default;

    /// <summary>Slot-name → layout id, e.g. <c>"primary" → "tile"</c>.</summary>
    public IReadOnlyDictionary<string, string> Slots { get; init; } =
        new Dictionary<string, string>
        {
            ["primary"] = "tile",
            ["secondary"] = "float",
            ["tertiary"] = "monocle",
            ["quaternary"] = "grid",
        };

    /// <summary>Per-layout option overrides, keyed by layout id.</summary>
    public IReadOnlyDictionary<string, LayoutOptions> PerLayoutOpts { get; init; } =
        new Dictionary<string, LayoutOptions>();

    /// <summary>Output-name → layout id (matches <c>river_output_v1.name</c>).</summary>
    public IReadOnlyDictionary<string, string> PerOutput { get; init; } =
        new Dictionary<string, string>();

    /// <summary>Border styling shared by every layout that draws borders.</summary>
    public BorderSpec Border { get; init; } = new(2, 0xFF88C0D0u, 0xFF3B4252u, 0xFFBF616Au);

    /// <summary>Configurable keybind table parsed from <c>[keybinds]</c>.</summary>
    public KeybindConfig Keybinds { get; init; } = new();

    /// <summary>Phase B1e — <c>[state]</c> + <c>[scratchpad]</c> sections.</summary>
    public StateConfig State { get; init; } = StateConfig.Default;

    /// <summary>
    /// SnapZones store parsed from <c>[[snapzones]]</c> /
    /// <c>[[snapzones.zone]]</c> arrays-of-tables. KZones-style: a
    /// floating window dropped over a zone snaps to that zone's
    /// resolved rectangle. Defaults to an empty store, which the
    /// drag pipeline treats as "snap-zones disabled".
    /// </summary>
    public SnapZoneStore SnapZones { get; init; } = SnapZoneStore.Empty;

    /// <summary>
    /// <c>[[exec]]</c> autostart entries — supervised commands that
    /// Aqueous launches after the compositor advertises its globals
    /// (the bar, wallpaper daemon, polkit agent, …).
    /// </summary>
    public ExecConfig Exec { get; init; } = ExecConfig.Empty;

    /// <summary>Compiled-in fallback config (used when no file is present).</summary>
    public static LayoutConfig Default { get; } = new();

    /// <summary>
    /// Returns the merged options for a given layout id: per-layout
    /// overrides win, otherwise the global defaults are returned. The
    /// per-layout <see cref="LayoutOptions.Extra"/> bag passes through
    /// untouched, which is how plugin-supplied layouts read their
    /// own knobs.
    /// </summary>
    public LayoutOptions OptionsFor(LayoutId layoutId) => OptionsFor(layoutId.Value);

    /// <summary>
    /// String-keyed overload of <see cref="OptionsFor(LayoutId)"/>. Kept
    /// because <see cref="ILayoutEngine.Id"/> is a <see cref="string"/>
    /// today — call sites with a raw protocol id pass through here.
    /// </summary>
    public LayoutOptions OptionsFor(string layoutId)
    {
        if (PerLayoutOpts.TryGetValue(layoutId, out var perLayout))
        {
            // Merge: per-layout `Extra` wins, common scalars from per-layout if non-zero
            // else from defaults.
            return new LayoutOptions(
                GapsOuter: perLayout.GapsOuter > 0 ? perLayout.GapsOuter : Defaults.GapsOuter,
                GapsInner: perLayout.GapsInner > 0 ? perLayout.GapsInner : Defaults.GapsInner,
                MasterRatio: perLayout.MasterRatio > 0 ? perLayout.MasterRatio : Defaults.MasterRatio,
                MasterCount: perLayout.MasterCount > 0 ? perLayout.MasterCount : Defaults.MasterCount,
                Extra: perLayout.Extra);
        }
        return Defaults;
    }

    /// <summary>
    /// Convenience wrapper around <see cref="LayoutConfigLoader.Load"/>.
    /// Kept for source compatibility; new code should call the loader
    /// directly.
    /// </summary>
    public static LayoutConfig Load(string path) => LayoutConfigLoader.Load(path);

    /// <summary>
    /// Convenience wrapper around <see cref="LayoutConfigLoader.Parse"/>.
    /// Kept for source compatibility; new code should call the loader
    /// directly.
    /// </summary>
    internal static LayoutConfig Parse(string text) => LayoutConfigLoader.Parse(text);
}
