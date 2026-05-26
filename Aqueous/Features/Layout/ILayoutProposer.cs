using System;
using System.Collections.Generic;

namespace Aqueous.Features.Layout;

/// <summary>
/// Public-facing layout-proposing surface that consumers (handlers, focus service, drag handler)
/// target.
/// <para>
/// Pump-thread only — every member assumes it is invoked from the Wayland event-dispatch thread.
/// </para>
/// </summary>
internal interface ILayoutProposer
{
    /// <summary>
    /// Drive the layout subsystem for one output (or, when <paramref name="output"/> is <see
    /// cref="IntPtr.Zero"/>, the virtual fallback area). Builds a snapshot of the visible windows,
    /// asks the active layout engine for placements, and emits <c>propose_dimensions</c> only when
    /// geometry differs.
    /// </summary>
    void ProposeForArea(IntPtr output, string? outputName, Rect usableArea);

    /// <summary>
    /// Two-rect overload: <paramref name="outputRect"/> is the raw output rectangle (no struts
    /// applied) consumed by the fullscreen branch and by any rule-matched window with
    /// <c>ignore_struts = true</c>; <paramref name="usableArea"/> is the strut-shrunk rect used by
    /// every other branch.
    /// </summary>
    void ProposeForArea(IntPtr output, string? outputName, Rect outputRect, Rect usableArea);

    /// <summary>
    /// True iff the active layout (resolved against the focused window's output) is the dedicated
    /// <c>float</c> engine. Used by the drag handler and the floating-toggle action to decide whether
    /// per-window floating overrides are honoured.
    /// </summary>
    bool IsFloatLayoutActive();

    /// <summary>
    /// Output-parametrised overload — used by the drag arming path where the focused window may be on
    /// a different output than the one being dragged.
    /// </summary>
    bool IsFloatLayoutActive(IntPtr output);

    /// <summary>
    /// Build a per-output <see cref="WindowEntryView"/> snapshot for navigation queries (directional
    /// focus, scrolling viewport).
    /// </summary>
    IReadOnlyList<WindowEntryView> BuildSnapshotFor(IntPtr output);

    /// <summary>
    /// Resolves an output proxy to its human-readable name (used by the layout engine when matching
    /// per-output config). Returns <c>null</c> when no name is available.
    /// </summary>
    string? ResolveOutputName(IntPtr output);

    /// <summary>
    /// Delegates to <c>LayoutController.FocusNeighbor</c>; returns the next window to focus or
    /// <c>null</c> if the engine has no preference (callers fall back to insertion-order cycling).
    /// </summary>
    IntPtr? LayoutFocusNeighbor(
        IntPtr output,
        string? outputName,
        IntPtr current,
        FocusDirection dir,
        IReadOnlyList<WindowEntryView> snapshot,
        uint visibleTags);
}
