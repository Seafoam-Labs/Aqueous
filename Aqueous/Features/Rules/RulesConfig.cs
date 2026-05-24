using System;
using System.Collections.Generic;

namespace Aqueous.Features.Rules;

/// <summary>
/// Window-anchor placement edge for a <see cref="WindowRule"/>. Mirrors the
/// <c>anchor = "center" | "top" | "bottom" | "left" | "right"</c> field in
/// <c>rules.toml</c>.
/// </summary>
public enum AnchorKind
{
    Center,
    Top,
    Bottom,
    Left,
    Right,
}

/// <summary>
/// Resolved size specification for a window-rule anchor. Discriminated by subtype so the
/// layout engine can branch without a sentinel-int representation. Always emitted by the
/// parser; falls back to <see cref="Native"/> when the user-supplied value is malformed.
/// </summary>
public abstract record SizeSpec
{
    /// <summary>Use the client's own requested buffer size (<c>size = "native"</c>).</summary>
    public sealed record Native : SizeSpec
    {
        public static readonly Native Instance = new();
    }

    /// <summary>Pin to an explicit pixel size (<c>size = "1920x1080"</c>).</summary>
    public sealed record Pixels(int W, int H) : SizeSpec;

    /// <summary>Pin to a fraction of the output's usable area (<c>size = "0.75x0.5"</c>).</summary>
    public sealed record Fraction(double W, double H) : SizeSpec;
}

/// <summary>
/// One <c>[[window]]</c> rule parsed from <c>rules.toml</c>. First-match-wins evaluation
/// happens in <c>WindowRuleEngine</c>; the parser only guarantees that every emitted
/// rule has at least one matcher set and a recognised layout id.
/// </summary>
public sealed record WindowRule(
    string? AppId,
    string? Class,
    string? Title,
    string Layout,
    AnchorKind Anchor,
    SizeSpec Size,
    double Scale,
    int? Tag,
    bool Fullscreen);

/// <summary>
/// Options for the <c>game-mode</c> layout engine, parsed from the <c>[game_mode]</c> section
/// of <c>rules.toml</c>. Lives in the rules file rather than <c>wm.toml</c> because the
/// engine is inert without a matching <see cref="WindowRule"/>.
/// </summary>
public sealed record GameModeOptions(
    string RemainderLayout,
    int GapsInner,
    string FallbackLayout)
{
    /// <summary>Default options applied when no <c>[game_mode]</c> section is present.</summary>
    public static readonly GameModeOptions Default = new(
        RemainderLayout: "grid",
        GapsInner: 8,
        FallbackLayout: "grid");
}

/// <summary>
/// In-memory representation of <c>~/.config/aqueous/rules.toml</c>. Parsed once at boot and
/// on every <c>Super+R</c> reload; missing file produces <see cref="Empty"/>.
/// </summary>
public sealed record RulesConfig(
    GameModeOptions GameMode,
    IReadOnlyList<WindowRule> Windows)
{
    /// <summary>Empty config — no rules, default game-mode options.</summary>
    public static readonly RulesConfig Empty = new(GameModeOptions.Default, Array.Empty<WindowRule>());
}
