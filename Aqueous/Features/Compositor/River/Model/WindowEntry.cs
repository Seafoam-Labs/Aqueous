using System;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Per-window state mirrored from <c>river_window_v1</c> events plus
/// derived data used by the layout/render passes. Promoted out of the
/// nested-class declaration inside <see cref="RiverWindowManagerClient"/>
/// during the Phase 2 readability refactor — semantics are unchanged.
/// </summary>
internal sealed class WindowEntry
{
    public IntPtr Proxy;
    public IntPtr NodeProxy;
    public string? Title;
    public string? AppId;
    public int WidthHint, HeightHint;
    public int W, H;
    public int X, Y;
    public bool Placed;
    public int ProposedW, ProposedH;
    public int LastHintW, LastHintH;
    public int MinW, MinH, MaxW, MaxH;
    public int LastPosX = int.MinValue, LastPosY = int.MinValue;
    public int LastClipW, LastClipH;
    public bool BordersSent;
    public bool ShowSent;

    // Phase B1e (partial): per-window floating override + remembered
    // floating rect. Set when the user drags a window with
    // Super+BTN_LEFT; honoured by ProposeForArea so floating windows
    // bypass the active layout engine and keep their dragged
    // position across manage cycles.
    public bool Floating;
    public bool HasFloatRect;
    public int FloatX, FloatY, FloatW, FloatH;

    // Phase B1b scrolling fix: visibility comes from the layout
    // engine's WindowPlacement.Visible. Off-screen scrolling
    // columns must NOT be repositioned/clipped/place_top'd, and
    // must NOT receive propose_dimensions storms. Defaults to
    // true so windows mapped before the first manage cycle stay
    // visible.
    public bool Visible = true;

    // Output the window currently belongs to. Set by manage_start
    // when the window's position falls inside an output's area
    // (or to the first output as a fallback). Used by
    // ProposeForArea to filter the per-output snapshot so engines
    // like ScrollingLayout do not see windows from other outputs
    // in their per-output ScrollState.
    public IntPtr Output;

    // Phase B1c — Tags / Workspaces.
    //
    // 32-bit tag bitmask. A window is rendered iff
    // (Tags & Output.VisibleTags) != 0. Default is tag 1
    // (bit 0). At manage_start a freshly-mapped window is
    // re-tagged to whatever its assigned output currently views
    // (minus the reserved scratchpad bit). See TagState for
    // semantics.
    public uint Tags = Aqueous.Features.Tags.TagState.DefaultTag;

    // Latched "the compositor currently considers this window
    // shown" cache. Only flipped by the manage_start visibility
    // pass; render_start uses this together with the
    // engine-driven Visible flag to decide whether to emit
    // show/place_top/borders this frame.
    public bool TagVisible = true;

    // Latch so we only emit hide (opcode 4) once per
    // visibility transition; without this we would re-send hide
    // every manage cycle for every off-tag window.
    public bool HideSent;
}
