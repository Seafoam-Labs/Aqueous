using System;
using System.Collections.Generic;

namespace Aqueous.Features.Layout;

/// <summary>
/// Plugin-facing geometry helpers shared by the built-in engines and available to custom <see
/// cref="ILayoutEngine"/> implementations.
/// </summary>
/// <remarks>
/// <para>
/// Engines must remain pure (no Wayland calls, no I/O). These helpers exist so a layout can
/// describe its policy in terms of named rectangle operations rather than re-deriving the same
/// arithmetic in every implementation.
/// </para>
/// <para>
/// Every helper is total (never throws on degenerate input) so the <see cref="LayoutController"/>
/// can rely on engine output without a per-call <c>try</c>/<c>catch</c>. Boundary behaviour is
/// documented per-method.
/// </para>
/// </remarks>
public static class LayoutMath
{
    /// <summary>
    /// Returns <paramref name="r"/> shrunk by <paramref name="margin"/> on every side. Never produces
    /// a rect with negative width / height; if <paramref name="margin"/> would consume the whole rect
    /// the result has W/H = 1.
    /// </summary>
    public static Rect Shrink(Rect r, int margin)
    {
        if (margin <= 0)
        {
            return r;
        }

        int w = Math.Max(1, r.W - 2 * margin);
        int h = Math.Max(1, r.H - 2 * margin);
        return new Rect(r.X + margin, r.Y + margin, w, h);
    }

    /// <summary>
    /// Returns the geometric intersection of <paramref name="a"/> and <paramref name="b"/> (both in
    /// the same coordinate space). When the two rects do not overlap — or either is degenerate
    /// (W/H &lt;= 0) — returns <see cref="Rect.Empty"/>. Total: never throws.
    /// </summary>
    public static Rect Intersect(Rect a, Rect b)
    {
        if (a.W <= 0 || a.H <= 0 || b.W <= 0 || b.H <= 0)
        {
            return Rect.Empty;
        }

        int x = Math.Max(a.X, b.X);
        int y = Math.Max(a.Y, b.Y);
        int right = Math.Min(a.Right, b.Right);
        int bottom = Math.Min(a.Bottom, b.Bottom);
        int w = right - x;
        int h = bottom - y;
        if (w <= 0 || h <= 0)
        {
            return Rect.Empty;
        }

        return new Rect(x, y, w, h);
    }

    /// <summary>
    /// Clamps a rect's W/H to a window's min/max hints. A hint of 0 is treated as "unbounded" (Wayland
    /// convention).
    /// </summary>
    public static Rect ClampToHints(Rect r, in WindowEntryView w)
    {
        int width = r.W;
        int height = r.H;
        if (w.MinW > 0 && width < w.MinW)
        {
            width = w.MinW;
        }

        if (w.MinH > 0 && height < w.MinH)
        {
            height = w.MinH;
        }

        if (w.MaxW > 0 && width > w.MaxW)
        {
            width = w.MaxW;
        }

        if (w.MaxH > 0 && height > w.MaxH)
        {
            height = w.MaxH;
        }

        return new Rect(r.X, r.Y, width, height);
    }

    /// <summary>
    /// Splits <paramref name="length"/> into <paramref name="count"/> evenly-sized cells with
    /// <paramref name="gap"/> pixels between them. The last cell absorbs any leftover from integer
    /// division so the cells together cover exactly <paramref name="length"/>. Returns the list of
    /// <c>(offset, size)</c> pairs along the axis.
    /// </summary>
    /// <remarks>
    /// Used by the built-in <c>tile</c> and <c>grid</c> layouts; plugin authors can compose it for any
    /// axis-aligned strip layout. Edge cases:
    /// <list type="bullet">
    /// <item>
    /// <paramref name="count"/> &lt;= 0 → returns an empty list.
    /// </item>
    /// <item>
    /// <paramref name="length"/> too small for the requested gaps → each cell is clamped to <c>1</c>;
    /// the last cell still absorbs the leftover (which may be negative).
    /// </item>
    /// </list>
    /// </remarks>
    public static IReadOnlyList<(int Offset, int Size)> SplitAxis(int length, int count, int gap)
    {
        if (count <= 0)
        {
            return Array.Empty<(int, int)>();
        }

        int totalGap = gap * (count - 1);
        int eachSize = Math.Max(1, (length - totalGap) / count);
        int leftover = Math.Max(0, length - totalGap - eachSize * count);

        var result = new (int, int)[count];
        int cur = 0;
        for (int i = 0; i < count; i++)
        {
            int size = eachSize + (i == count - 1 ? leftover : 0);
            result[i] = (cur, size);
            cur += size + gap;
        }

        return result;
    }
}
