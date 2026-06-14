using System;
using Aqueous.Features.Rules;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Per-window state mirrored from <c>river_window_v1</c> events plus derived data used by the
/// layout/render passes. Promoted out of the nested-class declaration inside <see
/// cref="RiverWindowManagerClient"/>.
/// </summary>
internal sealed class WindowEntry
{
    public IntPtr Proxy;
    public IntPtr NodeProxy;
    public string? Title;
    public string? AppId;

    /// <summary>
    /// X11 <c>WM_CLASS</c> as forwarded by <c>xwayland-satellite</c>; <see langword="null"/>
    /// for Wayland-native clients. River v1 does not yet expose a dedicated class event
    /// — this field is reserved for a future xwayland-satellite integration so the
    /// <c>[[window]] class = "..."</c> matcher in <c>rules.toml</c> has somewhere to land
    /// without another round of plumbing. Distinct from <see cref="AppId"/> on purpose.
    /// </summary>
    public string? XClass;
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
    // Cached last border state marshalled via river_window_v1.set_borders (opcode 8) so the
    // render pass only re-sends when the colour or width actually changes (e.g. focus switch).
    // LastBorderColor is the packed 0xAARRGGBB active colour; LastBorderWidth the edge width.
    public uint LastBorderColor;
    public int LastBorderWidth = int.MinValue;
    public bool ShowSent;

    // Decoration mode handling. DecorationHint caches the last decoration_hint event
    // (river_window_v1 event opcode 6): only_csd / prefers_csd / prefers_ssd / no_preference.
    // DecorationHintReceived gates the manage-pass apply until at least one hint has arrived.
    // SsdApplied latches once use_ssd (request opcode 7) has been marshalled so it is never
    // re-sent per manage cycle (mirrors the BordersSent latch above).
    public uint DecorationHint;
    public bool DecorationHintReceived;
    public bool SsdApplied;

    // Cached last per-window blur flag marshalled via river_window_v1.set_window_blur (opcode 25)
    // so the render pass only re-sends when the effective decision flips (rule change / global
    // [blur].enabled toggle on reload). WindowBlurSent latches the first emit so an unchanged
    // value is never re-sent (mirrors BordersSent above).
    public bool WindowBlurSent;
    public bool LastWindowBlurEnabled;

    // Cached last per-window opacity marshalled via river_window_v1.set_window_opacity (opcode 26)
    // so the render pass only re-sends when the effective value changes (rule change / global
    // [opacity] edit on reload). WindowOpacitySent latches the first emit so an unchanged value
    // is never re-sent (mirrors WindowBlurSent above).
    public bool WindowOpacitySent;
    public double LastWindowOpacity;

    // Per-window floating override + remembered floating rect. Set when the user drags a window with
    // Super+BTN_LEFT; honoured by ProposeForArea so floating windows bypass the active layout engine
    // and keep their dragged position across manage cycles.
    public bool Floating;
    public bool HasFloatRect;
    public int FloatX, FloatY, FloatW, FloatH;

    // Visibility comes from the layout engine's WindowPlacement.Visible.
    // Off-screen scrolling columns must NOT be repositioned/clipped/place_top'd, and must NOT receive
    // propose_dimensions storms. Defaults to true so windows mapped before the first manage cycle
    // stay visible.
    public bool Visible = true;

    // Output the window currently belongs to. Set by manage_start when the window's position falls
    // inside an output's area (or to the first output as a fallback). Used by ProposeForArea to
    // filter the per-output snapshot so engines like ScrollingLayout do not see windows from other
    // outputs in their per-output ScrollState.
    public IntPtr Output;

    // Workspace this window is assigned to: the ext_workspace_handle_v1 proxy the client last
    // passed to river_window_v1.set_workspace (opcode 24) via WorkspaceService. IntPtr.Zero means
    // "unassigned / visible on every workspace" (the default for freshly-mapped windows, mirroring
    // the Visible = true rationale above). LayoutProposer hides a window only when this handle is
    // still tracked by WorkspaceStore *and* that workspace is not the active one — a reaped handle
    // (untracked) is treated as visible so a freed workspace can never strand its windows.
    public IntPtr Workspace;

    // Tags / Workspaces. 32-bit tag bitmask. A window is rendered iff (Tags &
    // Output.VisibleTags) != 0. Default is tag 1 (bit 0). At manage_start a freshly-mapped window is
    // re-tagged to whatever its assigned output currently views (minus the reserved scratchpad bit).
    // See TagState for semantics.
    public uint Tags = Aqueous.Features.Tags.TagState.DefaultTag;

    // Latched "the compositor currently considers this window shown" cache. Only flipped by the
    // manage_start visibility pass; render_start uses this together with the engine-driven Visible
    // flag to decide whether to emit show/place_top/borders this frame.
    public bool TagVisible = true;

    // Latch so we only emit hide (opcode 4) once per visibility transition; without this we would
    // re-send hide every manage cycle for every off-tag window.
    public bool HideSent;
    // Xdg-shell maximized state-array flag mirror. Updated by
    // IWindowStateHost.SetToplevelMaximizedState on every enter/restore transition driven by
    // ToggleMaximize. Read by any future xdg_toplevel.configure marshal so the state array it sends
    // to strict xdg-shell clients (Chromium, Alacritty) matches Aqueous's idea of the window's
    // maximized state.
    public bool XdgMaximized;

    // ---- Game-mode runtime fields (read by LayoutProposer → GameModeLayout) ----------------
    // Game-mode anchor metadata. Populated by the rule engine on app_id/title changes
    // (see WindowEventService) and by FocusedWindowTracker on every focus transition.
    // LayoutProposer copies these into WindowEntryView so GameModeLayout can branch on
    // IsAnchor without re-running the rule engine each frame.

    /// <summary>Resolved window rule (or null if no rule matched). Refreshed on every
    /// app_id / title event. Read by <see cref="LayoutProposer"/> when building snapshots.</summary>
    public RulePlacement? Placement;

    /// <summary>Monotonically-increasing tick stamped whenever this window becomes the
    /// focused window. Used by <c>GameModeLayout</c> to pick the most-recently-focused
    /// anchor candidate on outputs that host multiple matching windows.</summary>
    public long LastFocusTick;

    /// <summary>
    /// Toplevel proxy representing the parent of this window.
    /// </summary>
    public IntPtr ParentProxy;
}
