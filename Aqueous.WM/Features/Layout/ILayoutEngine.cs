using System;
using System.Collections.Generic;

namespace Aqueous.WM.Features.Layout;

/// <summary>
/// A pure layout engine: given a usable area, the visible (non-floating,
/// non-fullscreen) windows, the focused window and per-engine options,
/// returns a list of <see cref="WindowPlacement"/>s.
/// </summary>
/// <remarks>
/// <para>
/// Engines are unit-testable because they never call into Wayland —
/// only <c>LayoutController</c> does. The fifth parameter is an opaque
/// per-output state slot the engine may use to remember things across
/// arrange calls (scrolling viewport offset, monocle current index,
/// master-stack ordering …). The controller stores it without
/// inspecting its shape.
/// </para>
/// </remarks>
/// <summary>Direction tokens for engine-aware focus / move / scroll actions.</summary>
public enum FocusDirection { Left, Right, Up, Down, Next, Prev }

public interface ILayoutEngine
{
    /// <summary>Stable id, e.g. <c>"tile"</c>.</summary>
    string Id { get; }

    IReadOnlyList<WindowPlacement> Arrange(
        Rect usableArea,
        IReadOnlyList<WindowEntryView> visibleWindows,
        IntPtr focusedWindow,
        LayoutOptions opts,
        ref object? perOutputState);

    /// <summary>
    /// Return the handle of the window that should receive focus when the
    /// user presses a directional focus key while this engine is active on
    /// <paramref name="output"/>. Default: <c>null</c> — the controller
    /// falls back to its layout-agnostic cycle. Engines that have a
    /// natural ordering (scrolling columns, master-stack indices)
    /// override this.
    /// </summary>
    IntPtr? FocusNeighbor(
        IntPtr output,
        IntPtr current,
        FocusDirection dir,
        IReadOnlyList<WindowEntryView> windows,
        ref object? perOutputState) => null;

    /// <summary>
    /// Move the focused window's slot by <paramref name="delta"/> within
    /// the engine's ordering (e.g. swap scrolling columns). Returns true
    /// if the engine handled the request. Default: no-op.
    /// </summary>
    bool MoveFocused(
        IntPtr output,
        IntPtr focused,
        FocusDirection dir,
        ref object? perOutputState) => false;

    /// <summary>
    /// Pan the engine's viewport by <paramref name="deltaColumns"/> without
    /// changing the focused window. Default: no-op (most engines have no
    /// viewport concept).
    /// </summary>
    void ScrollViewport(
        IntPtr output,
        int deltaColumns,
        ref object? perOutputState) {}
}

/// <summary>
/// Factory for an <see cref="ILayoutEngine"/>. One factory per layout id;
/// the registry keeps a single instance and asks it for new engines as
/// needed (most engines are stateless and the factory may return the same
/// shared instance).
/// </summary>
public interface ILayoutFactory
{
    string Id { get; }
    string DisplayName { get; }
    ILayoutEngine Create();
}
