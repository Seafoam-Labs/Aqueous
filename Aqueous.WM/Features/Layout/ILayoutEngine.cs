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
