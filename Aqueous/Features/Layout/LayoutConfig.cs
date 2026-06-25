using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Input;
using Aqueous.Features.State;

[assembly: InternalsVisibleTo("Aqueous.Tests")]

namespace Aqueous.Features.Layout;

/// <summary>
/// In-memory representation of <c>~/.config/aqueous/wm.toml</c>. Only the keys actually consumed
/// by the layout subsystem are modelled. Parsing lives in <see cref="LayoutConfigLoader"/> — this
/// file is the model and defaults only.
/// </summary>
public sealed record LayoutConfig
{
    /// <summary>
    /// Global default layout id (used when nothing else applies).
    /// </summary>
    public string DefaultLayout { get; init; } = "tile";

    public StrutsConfig Struts { get; init; } = new();

    public InputConfig Input { get; init; } = InputConfig.Default;

    /// <summary>
    /// Default options applied to every layout that doesn't override them.
    /// </summary>
    public LayoutOptions Defaults { get; init; } = LayoutOptions.Default;

    /// <summary>
    /// Slot-name → layout id, e.g. <c>"primary" → "tile"</c>.
    /// </summary>
    public IReadOnlyDictionary<string, string> Slots { get; init; } =
        new Dictionary<string, string>
        {
            ["primary"] = "tile",
            ["secondary"] = "float",
            ["tertiary"] = "monocle",
            ["quaternary"] = "grid",
        };

    /// <summary>
    /// Per-layout option overrides, keyed by layout id.
    /// </summary>
    public IReadOnlyDictionary<string, LayoutOptions> PerLayoutOpts { get; init; } =
        new Dictionary<string, LayoutOptions>();

    /// <summary>
    /// Output-name → layout id (matches <c>river_output_v1.name</c>).
    /// </summary>
    public IReadOnlyDictionary<string, string> PerOutput { get; init; } =
        new Dictionary<string, string>();

    /// <summary>
    /// Per-output layout overrides keyed by an EDID/make/model/serial <see cref="OutputSelector"/>
    /// instead of a connector name. Used when a <c>[[output]]</c> block specifies <c>edid =</c>
    /// (or <c>make</c>/<c>model</c>/<c>serial</c>) instead of (or in addition to) <c>name</c>.
    /// Resolution order: <see cref="PerOutput"/> name lookup first, then this list in declaration
    /// order (first match wins). The selector-based list is the port-independent identity.
    /// </summary>
    public IReadOnlyList<(OutputSelector Selector, string LayoutId)> PerOutputSelectors { get; init; } =
        Array.Empty<(OutputSelector, string)>();

    /// <summary>
    /// Per-workspace layout id, keyed by 1-based workspace number (workspace 1, 2, 3, …). Consulted
    /// after an explicit per-workspace override and the per-output config, but it ranks above
    /// <see cref="DefaultLayout"/>. Populated from <c>[[workspace]]</c> blocks without an
    /// <c>output</c> key.
    /// </summary>
    public IReadOnlyDictionary<int, string> PerWorkspace { get; init; } =
        new Dictionary<int, string>();

    /// <summary>
    /// Per-(output, workspace) layout id, for "monitor X workspace N = monocle". The string key is
    /// the connector name; the int is the 1-based workspace number. Most specific config override;
    /// wins over <see cref="PerWorkspace"/>. Populated from <c>[[workspace]]</c> blocks with an
    /// <c>output</c> key.
    /// </summary>
    public IReadOnlyDictionary<(string OutputName, int Workspace), string> PerOutputWorkspace { get; init; } =
        new Dictionary<(string, int), string>();

    /// <summary>
    /// Border styling shared by every layout that draws borders.
    /// </summary>
    public BorderSpec Border { get; init; } = new(2, 0xFF88C0D0u, 0xFF3B4252u, 0xFFBF616Au);

    /// <summary>
    /// Global backdrop-blur configuration parsed from the <c>[blur]</c> section of
    /// <c>wm.toml</c>. Sent once (and on reload) to riverdelta via the manager-level
    /// <c>river_window_manager_v1.set_blur</c> request; drawn by SceneFX optimized blur.
    /// </summary>
    public BlurSpec Blur { get; init; } = BlurSpec.Default;

    /// <summary>
    /// Global window-opacity configuration parsed from the <c>[opacity]</c> section of
    /// <c>wm.toml</c>. Sent once (and on reload) to riverdelta via the manager-level
    /// <c>river_window_manager_v1.set_opacity</c> request; per-window overrides come
    /// from <c>rules.toml</c> via <c>river_window_v1.set_window_opacity</c>.
    /// </summary>
    public OpacitySpec Opacity { get; init; } = OpacitySpec.Default;

    /// <summary>
    /// Configurable keybind table parsed from <c>[keybinds]</c>.
    /// </summary>
    public KeybindConfig Keybinds { get; init; } = new();

    /// <summary>
    /// When true, Aqueous asks every SSD-capable window to use server-side decoration
    /// (river_window_v1.use_ssd), suppressing the client's own titlebar / minimize /
    /// maximize / close buttons. Has no effect on only_csd clients (most GTK/GNOME apps) —
    /// a Wayland protocol limitation. Parsed from <c>[layout].force_ssd</c>.
    /// </summary>
    public bool ForceSsd { get; init; } = false;

    /// <summary>
    /// <c>[state]</c> + <c>[scratchpad]</c> sections.
    /// </summary>
    public StateConfig State { get; init; } = StateConfig.Default;


    /// <summary>
    /// <c>[[exec]]</c> Autostart entries — supervised commands that Aqueous launches after the
    /// compositor advertises its globals (the bar, wallpaper daemon, polkit agent, …).
    /// </summary>
    public ExecConfig Exec { get; init; } = ExecConfig.Empty;

    public ActionsConfig Actions { get; init; } = new();

    /// <summary>
    /// Compiled-in fallback config (used when no file is present).
    /// </summary>
    public static LayoutConfig Default { get; } = new();

    /// <summary>
    /// Returns the merged options for a given layout id: per-layout overrides win, otherwise the
    /// global defaults are returned. The per-layout <see cref="LayoutOptions.Extra"/> bag passes
    /// through untouched, which is how plugin-supplied layouts read their own knobs.
    /// </summary>
    public LayoutOptions OptionsFor(LayoutId layoutId) => OptionsFor(layoutId.Value);

    /// <summary>
    /// String-keyed overload of <see cref="OptionsFor(LayoutId)"/>. Kept because <see
    /// cref="ILayoutEngine.Id"/> is a <see cref="string"/> today — call sites with a raw protocol id
    /// pass through here.
    /// </summary>
    public LayoutOptions OptionsFor(string layoutId)
    {
        if (PerLayoutOpts.TryGetValue(layoutId, out var perLayout))
        {
            // Merge: per-layout `Extra` wins, common scalars from per-layout if non-zero else from defaults.
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
    /// Resolve the layout id for a physical output identified by its connector <paramref
    /// name="name"/> and optional EDID metadata (the same fields surfaced by
    /// <c>Aqueous.OutputDaemon</c>'s snapshot). Looks up <see cref="PerOutput"/> first by name,
    /// then walks <see cref="PerOutputSelectors"/> for an EDID/make/model/serial match. Returns
    /// <c>null</c> when no override applies — callers fall back to <see cref="DefaultLayout"/>.
    /// </summary>
    public string? ResolveLayoutForOutput(
        string? name,
        string? edidSha256 = null,
        string? make = null,
        string? model = null,
        string? serial = null)
    {
        if (!string.IsNullOrEmpty(name) && PerOutput.TryGetValue(name, out var byName))
        {
            return byName;
        }

        foreach (var (sel, id) in PerOutputSelectors)
        {
            if (sel.Matches(name, edidSha256, make, model, serial))
            {
                return id;
            }
        }

        return null;
    }

    public string? ResolveLayoutForWorkspace(string? outputName, int workspaceNumber)
    {
        if (workspaceNumber <= 0)
        {
            return null;
        }

        if (!string.IsNullOrEmpty(outputName)
            && PerOutputWorkspace.TryGetValue((outputName!, workspaceNumber), out var byBoth))
        {
            return byBoth;
        }

        if (PerWorkspace.TryGetValue(workspaceNumber, out var byWs))
        {
            return byWs;
        }

        return null;
    }

    /// <summary>
    /// Convenience wrapper around <see cref="LayoutConfigLoader.Load"/>. Kept for source
    /// compatibility; new code should call the loader directly.
    /// </summary>
    public static LayoutConfig Load(string path) => LayoutConfigLoader.Load(path);

    /// <summary>
    /// Convenience wrapper around <see cref="LayoutConfigLoader.Parse"/>. Kept for source
    /// compatibility; new code should call the loader directly.
    /// </summary>
    internal static LayoutConfig Parse(string text) => LayoutConfigLoader.Parse(text);
}
