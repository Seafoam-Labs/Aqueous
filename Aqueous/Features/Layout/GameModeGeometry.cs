using Aqueous.Features.Rules;

namespace Aqueous.Features.Layout;

/// <summary>
/// Pure geometry kernel for the <c>game-mode</c> layout.
/// <para>
/// Turns <c>(usableArea, requestedBuffer, SizeSpec, AnchorKind, scale)</c> into two
/// rectangles:
/// </para>
/// <list type="bullet">
/// <item><see cref="ResolveAnchor"/> — where the anchored window (e.g. a fullscreen-ish
/// game requesting a sub-native buffer) gets drawn, always clamped inside
/// <paramref name="usableArea"/>.</item>
/// <item><see cref="ResolveRemainder"/> — the single largest band (top / bottom / left /
/// right) of free space surrounding the anchor, handed to whatever sub-layout
/// (<c>grid</c> by default) tiles the remaining windows.</item>
/// </list>
/// <para>
/// Side-effect-free, allocation-free beyond the returned structs, AOT-clean. All math is
/// integer; the single <c>double → int</c> conversion site (<see cref="SizeSpec.Fraction"/>)
/// uses truncation for cross-platform determinism.
/// </para>
/// <para>
/// v1 design choice ("band remainder"): a single <see cref="Rect"/> is returned, not an
/// <c>IReadOnlyList&lt;Rect&gt;</c>. Picking up the other three bands would require an
/// <c>ILayoutEngine</c> interface refactor and is deferred to v2.
/// </para>
/// </summary>
public static class GameModeGeometry
{
    /// <summary>
    /// Resolves the rectangle the anchored window should occupy inside
    /// <paramref name="usableArea"/>.
    /// <para>
    /// Size resolution order: <see cref="SizeSpec"/> picks the base size
    /// (<c>Native</c> → <paramref name="requestedBufferW"/> / <paramref name="requestedBufferH"/>;
    /// <c>Pixels</c> → explicit; <c>Fraction</c> → fraction of <paramref name="usableArea"/>
    /// truncated to int), then <paramref name="scale"/> is multiplied in, then the result is
    /// clamped per-axis to <paramref name="usableArea"/>. Placement is then driven by
    /// <paramref name="anchor"/>: <see cref="AnchorKind.Center"/> centers on both axes;
    /// edge anchors pin one axis to the corresponding side and center the other.
    /// </para>
    /// </summary>
    public static Rect ResolveAnchor(
        Rect usableArea,
        int requestedBufferW,
        int requestedBufferH,
        SizeSpec spec,
        AnchorKind anchor,
        double scale)
    {
        // 1. Base size from SizeSpec.
        int w;
        int h;
        switch (spec)
        {
            case SizeSpec.Pixels p:
                w = p.W;
                h = p.H;
                break;
            case SizeSpec.Fraction f:
                w = (int)(usableArea.W * f.W);
                h = (int)(usableArea.H * f.H);
                break;
            default: // Native (and any future subtype falls back to native)
                w = requestedBufferW;
                h = requestedBufferH;
                break;
        }

        // 2. Apply scale.
        if (scale > 0 && scale != 1.0)
        {
            w = (int)(w * scale);
            h = (int)(h * scale);
        }

        // 3. Clamp per-axis (also defends against non-positive sizes).
        if (w < 1) w = 1;
        if (h < 1) h = 1;
        if (w > usableArea.W) w = usableArea.W;
        if (h > usableArea.H) h = usableArea.H;

        // 4. Place by anchor.
        int x;
        int y;
        switch (anchor)
        {
            case AnchorKind.Top:
                x = usableArea.X + (usableArea.W - w) / 2;
                y = usableArea.Y;
                break;
            case AnchorKind.Bottom:
                x = usableArea.X + (usableArea.W - w) / 2;
                y = usableArea.Y + usableArea.H - h;
                break;
            case AnchorKind.Left:
                x = usableArea.X;
                y = usableArea.Y + (usableArea.H - h) / 2;
                break;
            case AnchorKind.Right:
                x = usableArea.X + usableArea.W - w;
                y = usableArea.Y + (usableArea.H - h) / 2;
                break;
            default: // Center
                x = usableArea.X + (usableArea.W - w) / 2;
                y = usableArea.Y + (usableArea.H - h) / 2;
                break;
        }

        return new Rect(x, y, w, h);
    }

    /// <summary>
    /// Returns the largest of the four bands (top / bottom / left / right) that surround
    /// <paramref name="anchorRect"/> inside <paramref name="usableArea"/>.
    /// <para>
    /// Bands with zero area are excluded from contention entirely. This means:
    /// </para>
    /// <list type="bullet">
    /// <item>If the anchor spans the full height of the usable area
    /// (<c>anchor.H == usableArea.H</c>), the top and bottom bands collapse to zero height
    /// and drop out; only the left/right side bands compete. Typical case: a 3840×2160 game
    /// on a 7680×2160 ultrawide.</item>
    /// <item>If the anchor spans the full width (<c>anchor.W == usableArea.W</c>), the left
    /// and right bands collapse to zero width and drop out; only the top/bottom bands
    /// compete.</item>
    /// <item>If the anchor touches one side (e.g. <c>anchor.Y == usableArea.Y</c>), that
    /// side's band has zero height and is excluded.</item>
    /// </list>
    /// <para>
    /// Ties among surviving bands are broken in the order top → bottom → left → right.
    /// Returns <see cref="Rect.Empty"/> when no band survives (anchor fully covers usable
    /// area).
    /// </para>
    /// </summary>
    public static Rect ResolveRemainder(Rect usableArea, Rect anchorRect)
    {
        // Four candidate bands; any may have zero width or height.
        var top = new Rect(
            usableArea.X,
            usableArea.Y,
            usableArea.W,
            anchorRect.Y - usableArea.Y);

        var bottom = new Rect(
            usableArea.X,
            anchorRect.Bottom,
            usableArea.W,
            usableArea.Bottom - anchorRect.Bottom);

        var left = new Rect(
            usableArea.X,
            usableArea.Y,
            anchorRect.X - usableArea.X,
            usableArea.H);

        var right = new Rect(
            anchorRect.Right,
            usableArea.Y,
            usableArea.Right - anchorRect.Right,
            usableArea.H);

        // Priority order preserved by strict '>' below: top → bottom → left → right.
        Rect best = Rect.Empty;
        long bestArea = 0;

        long area;

        area = (long)top.W * top.H;
        if (area > 0 && area > bestArea) { best = top; bestArea = area; }

        area = (long)bottom.W * bottom.H;
        if (area > 0 && area > bestArea) { best = bottom; bestArea = area; }

        area = (long)left.W * left.H;
        if (area > 0 && area > bestArea) { best = left; bestArea = area; }

        area = (long)right.W * right.H;
        if (area > 0 && area > bestArea) { best = right; bestArea = area; }

        return best;
    }

    /// <summary>
    /// Returns the two full-height side bands flanking <paramref name="anchorRect"/> inside
    /// <paramref name="usableArea"/>: the left band (from <c>usableArea.X</c> up to
    /// <c>anchorRect.X</c>) and the right band (from <c>anchorRect.Right</c> up to
    /// <c>usableArea.Right</c>).
    /// <para>
    /// Either side may be <see cref="Rect.Empty"/> when the anchor is flush against that
    /// edge (e.g. an edge-anchored game collapses one side to zero width). Callers must
    /// check before handing a side to a sub-layout.
    /// </para>
    /// <para>
    /// v1.5 design choice: only the two side columns are exposed; the top and bottom
    /// strips above and below the anchor are intentionally unused. This keeps the
    /// geometry trivial (no rounding distribution, no multi-region abstraction) and
    /// matches the "anchor + left column + right column" mental model. Top/bottom
    /// support is explicitly out of scope.
    /// </para>
    /// </summary>
    public static (Rect Left, Rect Right) ResolveSideColumns(Rect usableArea, Rect anchorRect)
    {
        int leftW = anchorRect.X - usableArea.X;
        int rightW = usableArea.Right - anchorRect.Right;

        var left = leftW > 0
            ? new Rect(usableArea.X, usableArea.Y, leftW, usableArea.H)
            : Rect.Empty;

        var right = rightW > 0
            ? new Rect(anchorRect.Right, usableArea.Y, rightW, usableArea.H)
            : Rect.Empty;

        return (left, right);
    }
}
