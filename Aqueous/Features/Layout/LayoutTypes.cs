using System;
using System.Collections.Generic;
using Aqueous.Features.Rules;

namespace Aqueous.Features.Layout;

/// <summary>
/// Axis-aligned rectangle in logical pixels.
/// </summary>
public readonly record struct Rect(int X, int Y, int W, int H)
{
    public int Right => X + W;
    public int Bottom => Y + H;
    public static readonly Rect Empty = new(0, 0, 0, 0);
}

/// <summary>
/// Read-only view of a window the layout engine is allowed to see. Engines are pure: they never
/// mutate window state, they only return <see cref="WindowPlacement"/>s describing where the
/// controller should place the window.
/// </summary>
public readonly record struct WindowEntryView(
    IntPtr Handle,
    int MinW, int MinH, int MaxW, int MaxH,
    bool Floating,
    bool Fullscreen,
    uint Tags,
    // ---- Game-mode anchor metadata. All optional / defaulted so non-game-mode call
    // sites are unaffected. When unset, IsAnchor=false and GameModeLayout falls back
    // byte-identically to its configured fallback layout.
    RulePlacement? Placement = null,
    int RequestedBufferW = 0,
    int RequestedBufferH = 0,
    long LastFocusTick = 0L)
{
    /// <summary>
    /// Convenience: true iff a rule attached a non-fullscreen <c>game-mode</c> placement
    /// to this window. Mirrors <see cref="RulePlacement.IsAnchor"/> so layout engines can
    /// branch without a null check.
    /// </summary>
    public bool IsAnchor => Placement is { IsAnchor: true };
}

/// <summary>
/// Border parameters; <see cref="None"/> represents "no border at all". Colours are 0xAARRGGBB
/// packed.
/// </summary>
public readonly record struct BorderSpec(int Width, uint Focused, uint Normal, uint Urgent)
{
    public static readonly BorderSpec None = new(0, 0, 0, 0);
}

/// <summary>
/// Global backdrop-blur parameters parsed from the <c>[blur]</c> section of <c>wm.toml</c>.
/// <see cref="Enabled"/> toggles whether riverdelta creates the SceneFX optimized-blur node at
/// all; <see cref="Radius"/> and <see cref="Passes"/> map directly onto
/// <c>wlr_scene_set_blur_data</c>.
/// </summary>
public readonly record struct BlurSpec(bool Enabled, int Radius, int Passes)
{
    /// <summary>Blur off by default, with sane parameters used once it is enabled.</summary>
    public static readonly BlurSpec Default = new(false, 5, 3);
}

/// <summary>
/// What a layout engine returns for a single window: target geometry, stacking order and whether
/// the controller should actually show the window this frame (off-screen / monocle-hidden windows
/// return <c>Visible=false</c>).
/// </summary>
public readonly record struct WindowPlacement(
    IntPtr Handle,
    Rect Geometry,
    int ZOrder,
    bool Visible,
    BorderSpec Border);

/// <summary>
/// Options consumed by every engine plus a per-engine extension bag.
/// </summary>
public sealed record LayoutOptions(
    int GapsOuter,
    int GapsInner,
    double MasterRatio,
    int MasterCount,
    IReadOnlyDictionary<string, string> Extra)
{
    public static readonly LayoutOptions Default =
        new(8, 4, 0.55, 1, new Dictionary<string, string>());

    /// <summary>
    /// Raw output rectangle for the output currently being arranged (no struts applied).
    /// Engines that honour per-window <c>ignore_struts</c> (e.g. <c>GameModeLayout</c>) resolve
    /// matched windows against this rect instead of <c>usableArea</c>. Defaults to
    /// <see cref="Rect.Empty"/>; consumers must treat <c>(W &lt;= 0 || H &lt;= 0)</c> as
    /// "fall back to usableArea". The controller populates this on every <c>Arrange</c> call.
    /// </summary>
    public Rect OutputRect { get; init; } = Rect.Empty;

    /// <summary>
    /// Border styling for the output currently being arranged. Engines emit this on every visible
    /// <see cref="WindowPlacement"/> so the proposer can pick the focused/normal/urgent colour and
    /// width per window. Defaults to <see cref="BorderSpec.None"/> (borders disabled).
    /// </summary>
    public BorderSpec Border { get; init; } = BorderSpec.None;

    public string? GetExtra(string key) =>
        Extra.TryGetValue(key, out var v) ? v : null;

    public double GetExtraDouble(string key, double fallback) =>
        Extra.TryGetValue(key, out var v) && double.TryParse(v,
            System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture,
            out var d) ? d : fallback;

    public bool GetExtraBool(string key, bool fallback) =>
        Extra.TryGetValue(key, out var v)
            ? v.Equals("true", StringComparison.OrdinalIgnoreCase) ||
              v == "1" || v.Equals("yes", StringComparison.OrdinalIgnoreCase)
            : fallback;
}
