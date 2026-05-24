using System;
using Aqueous.Features.Layout;
using Aqueous.Features.Rules;

namespace Aqueous.Features.State;

/// <summary>
/// Phase B1e — high-level window state used by <see cref="WindowStateController"/> to drive layout
/// filtering and render-path overrides.
/// <para>
/// <see cref="Tiled"/> and <see cref="Floating"/> are mutually exclusive "base" modes; the
/// remaining values are *overlays* that suspend the underlying mode and remember it in
/// <c>PreviousState</c> on the owning <c>WindowEntry</c>.
/// </para>
/// </summary>
public enum WindowState : byte
{
    /// <summary>
    /// Default — participates in the active layout engine.
    /// </summary>
    Tiled,
    /// <summary>
    /// Free geometry, still visible &amp; focusable, ignores the layout.
    /// </summary>
    Floating,
    /// <summary>
    /// Covers the usable area of its output (minus gaps); above tiles.
    /// </summary>
    Maximized,
    /// <summary>
    /// Covers the raw output rect; topmost; no border, no layer-shell padding.
    /// </summary>
    Fullscreen,
    /// <summary>
    /// Hidden from layout + focus list; retrievable via <c>UnminimizeLast</c>.
    /// </summary>
    Minimized,
    /// <summary>
    /// Hidden until summoned; dropdown-style float on summon.
    /// </summary>
    Scratchpad,
}

/// <summary>
/// Per-window state snapshot used by <see cref="WindowStateController"/>. The river client owns
/// the actual <c>WindowEntry</c>; this record is the protocol-agnostic projection passed between
/// the controller and its host.
/// </summary>
public sealed class WindowStateData
{
    public WindowProxy Handle { get; init; }
    public WindowState State { get; set; } = WindowState.Tiled;
    public WindowState PreviousState { get; set; } = WindowState.Tiled;

    /// <summary>
    /// Last floating rectangle (.
    /// </summary>
    public Rect? FloatingGeom { get; set; }

    /// <summary>
    /// Geometry snapshot taken before entering FS / Maximize.
    /// </summary>
    public Rect? PreFsGeom { get; set; }

    /// <summary>
    /// Output the window is pinned to while FS / Maximized.
    /// </summary>
    public OutputProxy PinnedOutput { get; set; }

    /// <summary>
    /// True iff the window is parked in a scratchpad and currently hidden.
    /// </summary>
    public bool InScratchpad { get; set; }

    /// <summary>
    /// Visibility flag honoured by the render path; toggled by scratchpad summon/dismiss.
    /// </summary>
    public bool Visible { get; set; } = true;

    /// <summary>
    /// Name of the scratchpad slot that owns this window, or <c>null</c>.
    /// </summary>
    public string? ScratchpadName { get; set; }

    /// <summary>
    /// Window-rule placement attached on <c>manage_start</c> / identity change, or
    /// <see langword="null"/> when no rule matches. PR #2 is inert at the layout level — this
    /// field is populated but not yet consumed by any layout engine. The upcoming
    /// <c>GameModeLayout</c> (PR #4) reads <see cref="IsAnchor"/> to pick the exclusion anchor.
    /// </summary>
    public RulePlacement? Placement { get; set; }

    /// <summary>
    /// Shorthand: this window is the output's exclusion anchor iff a rule attached
    /// a non-fullscreen <c>game-mode</c> placement. Mirrors
    /// <see cref="RulePlacement.IsAnchor"/> so consumers can branch without a null check.
    /// </summary>
    public bool IsAnchor => Placement is { IsAnchor: true };
}
