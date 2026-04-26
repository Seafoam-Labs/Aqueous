using System;

namespace Aqueous.WM.Features.Layout;

/// <summary>
/// Tiny helpers shared by the built-in engines.
/// </summary>
internal static class LayoutMath
{
    /// <summary>
    /// Returns <paramref name="r"/> shrunk by <paramref name="margin"/> on
    /// every side. Never produces a rect with negative width / height; if
    /// <paramref name="margin"/> would consume the whole rect the result
    /// has W/H = 1.
    /// </summary>
    public static Rect Shrink(Rect r, int margin)
    {
        if (margin <= 0) return r;
        int w = Math.Max(1, r.W - 2 * margin);
        int h = Math.Max(1, r.H - 2 * margin);
        return new Rect(r.X + margin, r.Y + margin, w, h);
    }

    /// <summary>Clamp a rect's W/H to a window's min/max hints. 0 hint = unbounded.</summary>
    public static Rect ClampToHints(Rect r, in WindowEntryView w)
    {
        int width  = r.W;
        int height = r.H;
        if (w.MinW > 0 && width  < w.MinW) width  = w.MinW;
        if (w.MinH > 0 && height < w.MinH) height = w.MinH;
        if (w.MaxW > 0 && width  > w.MaxW) width  = w.MaxW;
        if (w.MaxH > 0 && height > w.MaxH) height = w.MaxH;
        return new Rect(r.X, r.Y, width, height);
    }
}
