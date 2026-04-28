using System.Collections.Generic;
using Aqueous.Features.Layout;

namespace Aqueous.Features.SnapZones;

/// <summary>
/// A named bag of <see cref="SnapZone"/>s. Pure data + two pure
/// functions (<see cref="Resolve"/> and <see cref="Hit"/>); both are
/// trivially unit-testable without any Wayland surface.
///
/// <para>Multiple layouts per output are supported (KZones-style):
/// callers are expected to keep a "current layout index" per output and
/// flip it via a keybind. The store is layout-agnostic — it just hands
/// the controller a list of layouts and lets the controller pick.</para>
/// </summary>
public sealed class SnapZoneLayout
{
    /// <summary>
    /// Human-readable layout name (e.g. <c>"default"</c>, <c>"thirds"</c>).
    /// Surfaces in logs and, eventually, in an on-screen layout picker.
    /// </summary>
    public string Name { get; init; } = "default";

    /// <summary>The zones, in declaration order.</summary>
    public IReadOnlyList<SnapZone> Zones { get; init; } = System.Array.Empty<SnapZone>();

    /// <summary>
    /// Resolve a single zone's normalized rect against an output's
    /// usable area (the output rect minus any layer-shell exclusive
    /// zones, e.g. panels). Negative or out-of-range normalized values
    /// are clamped to <c>[0.0, 1.0]</c> rather than rejected so that a
    /// slightly-misconfigured layout still produces a usable rectangle.
    /// </summary>
    public static Rect Resolve(SnapZone z, Rect usable)
    {
        double nx = Clamp01(z.NX);
        double ny = Clamp01(z.NY);
        double nw = Clamp01(z.NW);
        double nh = Clamp01(z.NH);

        // Resolve to integers at the very last step so accumulated
        // rounding error doesn't bias multi-zone tilings.
        int x = usable.X + (int)(nx * usable.W);
        int y = usable.Y + (int)(ny * usable.H);
        int w = (int)(nw * usable.W);
        int h = (int)(nh * usable.H);

        // Refuse degenerate zones — caller (controller) treats Empty
        // as "no snap" and leaves the window where it was dropped.
        if (w <= 0 || h <= 0)
        {
            return Rect.Empty;
        }

        return new Rect(x, y, w, h);
    }

    /// <summary>
    /// Hit-test the pointer (in compositor logical coordinates, the
    /// same space as <see cref="Rect"/> and
    /// <see cref="Aqueous.Features.Compositor.River.OutputEntry"/>).
    /// Returns the first containing zone, matching declaration order
    /// — overlap is permitted in the schema, earlier wins.
    /// </summary>
    public SnapZone? Hit(int px, int py, Rect usable)
    {
        for (int i = 0; i < Zones.Count; i++)
        {
            var r = Resolve(Zones[i], usable);
            if (r.W <= 0 || r.H <= 0)
            {
                continue;
            }

            if (px >= r.X && px < r.X + r.W && py >= r.Y && py < r.Y + r.H)
            {
                return Zones[i];
            }
        }

        return null;
    }

    private static double Clamp01(double v) =>
        v < 0.0 ? 0.0 : v > 1.0 ? 1.0 : v;
}
