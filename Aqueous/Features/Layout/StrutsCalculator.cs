using System;
using Aqueous.Features.Compositor.River;

namespace Aqueous.Features.Layout;

/// <summary>
/// Pure helper that subtracts a <see cref="StrutsConfig"/> (top/bottom/left/right reserved-space
/// inset) from a raw output rect, clamping width/height to ≥1.
/// <para>
/// Lifted out of <c>RiverWindowManagerClient.WindowStateHostAccessors.ApplyStruts</c> so the
/// algorithm no longer lives on the god class. The accessor on the god class is retained
/// (delegating here) as a net-additive mirror — consumers will be to call this helper directly in
/// subsequent §2.x lifts, and the accessor retires with the rest of the partial when the god class
/// is demolished (§2.13).
/// </para>
/// <para>
/// Stateless on purpose: the active <see cref="LayoutConfig.Struts"/> changes at runtime (config
/// reload swaps the whole <see cref="LayoutConfig"/> instance), so the caller passes in the
/// current snapshot rather than the calculator caching one.
/// </para>
/// </summary>
internal static class StrutsCalculator
{
    /// <summary>
    /// Returns <paramref name="raw"/> with the four <paramref name="struts"/> inset values subtracted.
    /// A <c>null</c> or all-zero struts config short-circuits and returns <paramref name="raw"/>
    /// unchanged.
    /// </summary>
    internal static Rect Apply(Rect raw, StrutsConfig? struts)
    {
        if (struts is null)
        {
            return raw;
        }

        if ((struts.Top | struts.Bottom | struts.Left | struts.Right) == 0)
        {
            return raw;
        }

        var x = raw.X + struts.Left;
        var y = raw.Y + struts.Top;
        var w = Math.Max(1, raw.W - struts.Left - struts.Right);
        var h = Math.Max(1, raw.H - struts.Top - struts.Bottom);
        return new Rect(x, y, w, h);
    }
}
