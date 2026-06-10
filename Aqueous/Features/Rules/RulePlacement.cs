namespace Aqueous.Features.Rules;

/// <summary>
/// Per-window attachment produced when a managed window matches a <see cref="WindowRule"/>.
/// Stored on the corresponding <c>WindowStateData</c> (see the <c>Placement</c> field) so
/// <c>GameModeLayout</c> can read it without re-running the rule engine on every arrange call.
/// </summary>
/// <param name="Rule">The rule that produced this placement.</param>
public sealed record RulePlacement(WindowRule Rule)
{
    /// <summary>
    /// Convenience predicate matching the contract documented in the implementation plan:
    /// the window is the output's exclusion anchor iff its rule targets the
    /// <c>game-mode</c> layout and does <em>not</em> request true fullscreen (which would
    /// route through the existing <c>toggle_fullscreen</c> path instead).
    /// </summary>
    public bool IsAnchor =>
        string.Equals(Rule.Layout, "game-mode", System.StringComparison.Ordinal)
        && !Rule.Fullscreen;

    /// <summary>
    /// Per-window blur override resolved from the matching rule's <c>blur = …</c> field.
    /// <see langword="null"/> means "inherit the global <c>[blur].enabled</c> default";
    /// <see langword="false"/> force-excludes the window (e.g. games); <see langword="true"/>
    /// force-includes it. Read by <c>LayoutProposer</c> when marshalling
    /// <c>river_window_v1.set_window_blur</c>.
    /// </summary>
    public bool? BlurOverride => Rule.Blur;
}
