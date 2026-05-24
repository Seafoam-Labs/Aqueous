namespace Aqueous.Features.Rules;

/// <summary>
/// Per-window attachment produced when a managed window matches a <see cref="WindowRule"/>.
/// Stored on the corresponding <c>WindowStateData</c> (see the <c>Placement</c> field) so the
/// upcoming <c>GameModeLayout</c> engine (PR #4) can read it without re-running the rule
/// engine on every arrange call.
/// <para>
/// PR #2 is intentionally inert at the layout level: <see cref="RulePlacement"/> records are
/// produced and attached, but no layout engine consumes the <c>IsAnchor</c> flag yet.
/// </para>
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
}
