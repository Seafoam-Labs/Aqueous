using System;
using Aqueous.Features.Layout;
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

    // Last edges bitfield marshalled via river_window_v1.set_tiled (opcode 9). Sentinel -1 means
    // "never sent". Tiled windows are told edges = 0xF (all four edges), floating windows edges = 0
    // (none). Without set_tiled the xdg toplevel is left in the non-tiled state, so well-behaved
    // clients (ghostty and similar terminals) treat the imposed size as advisory and revert to
    // their own default — the root cause of "not all windows render at the correct size".
    public int LastTiledEdges = -1;

    public int LastHintW, LastHintH;
    public int MinW, MinH, MaxW, MaxH;
    public int LastPosX = int.MinValue, LastPosY = int.MinValue;
    public int LastClipW, LastClipH;
    public bool BordersSent;
    public BorderSpec LastResolvedBorder = BorderSpec.None;
    // Last border state marshalled via river_window_v1.set_borders (opcode 8). Render sequences
    // re-declare this state every time; these fields are bookkeeping for diagnostics/future readers.
    // LastBorderColor is the packed 0xAARRGGBB active colour; LastBorderWidth the edge width.
    public uint LastBorderColor;
    public int LastBorderWidth = int.MinValue;
    public bool ShowSent;

    // Current "show (opcode 5) has been emitted and not yet superseded by a hide" latch. Unlike
    // ShowSent (which is a one-shot liveness proof that the proxy was ever bound), this is flipped
    // back to false whenever the window is hidden, so render sequences re-emit show only on a real
    // hidden→visible transition instead of every frame. Re-sending show every pass churns the
    // wlroots scene graph and contributes to the slide stutter/afterimage.
    public bool ShownVisible;

    // Decoration mode handling. DecorationHint caches the last decoration_hint event
    // (river_window_v1 event opcode 6): only_csd / prefers_csd / prefers_ssd / no_preference.
    // DecorationHintReceived gates the manage-pass apply until at least one hint has arrived.
    // SsdApplied latches once use_ssd (request opcode 7) has been marshalled so it is never
    // re-sent per manage cycle (mirrors the BordersSent latch above).
    public uint DecorationHint;
    public bool DecorationHintReceived;
    public bool SsdApplied;

    // Last per-window blur flag marshalled via river_window_v1.set_window_blur (opcode 25). Render
    // sequences re-declare this state every time; these fields are bookkeeping only.
    public bool WindowBlurSent;
    public bool LastWindowBlurEnabled;

    // Last per-window opacity marshalled via river_window_v1.set_window_opacity (opcode 26). Render
    // sequences re-declare this state every time; these fields are bookkeeping only.
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

    // Latch so we only emit hide (opcode 4) once per visibility transition; without this we would
    // re-send hide every manage cycle for every workspace-hidden or off-layout window.
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
