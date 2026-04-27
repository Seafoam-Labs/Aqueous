using System;
using System.Collections.Generic;

namespace Aqueous.Features.Layout;

/// <summary>
/// Axis-aligned rectangle in logical pixels.
/// </summary>
public readonly record struct Rect(int X, int Y, int W, int H)
{
    public int Right  => X + W;
    public int Bottom => Y + H;
    public static readonly Rect Empty = new(0, 0, 0, 0);
}

/// <summary>
/// Read-only view of a window the layout engine is allowed to see.
/// Engines are pure: they never mutate window state, they only return
/// <see cref="WindowPlacement"/>s describing where the controller should
/// place the window.
/// </summary>
public readonly record struct WindowEntryView(
    IntPtr Handle,
    int MinW, int MinH, int MaxW, int MaxH,
    bool Floating,
    bool Fullscreen,
    uint Tags);

/// <summary>
/// Border parameters; <see cref="None"/> represents "no border at all".
/// Colours are 0xAARRGGBB packed.
/// </summary>
public readonly record struct BorderSpec(int Width, uint Focused, uint Normal, uint Urgent)
{
    public static readonly BorderSpec None = new(0, 0, 0, 0);
}

/// <summary>
/// What a layout engine returns for a single window: target geometry,
/// stacking order and whether the controller should actually show the
/// window this frame (off-screen / monocle-hidden windows return
/// <c>Visible=false</c>).
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
