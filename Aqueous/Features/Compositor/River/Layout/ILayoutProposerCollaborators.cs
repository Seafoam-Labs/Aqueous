using System;
using System.Collections.Generic;
using Aqueous.Features.Layout;

namespace Aqueous.Features.Compositor.River.Layout;

/// <summary>
/// Stage 5 transient bridge: each member is a temporary hook back
/// into <see cref="RiverWindowManagerClient"/> so the new
/// <see cref="Aqueous.Features.Layout.LayoutProposer"/> facade can
/// delegate to the partial without requiring the full 762-line lift
/// in one PR. The XML-doc on each member names the stage that retires
/// it; when the last member is gone, this interface disappears.
///
/// <para>
/// Single-implementation by design — only <see cref="RiverWindowManagerClient"/>
/// implements it explicitly. Tests fake this interface directly.
/// </para>
/// </summary>
internal interface ILayoutProposerCollaborators
{
    /// <summary>Delegates to the partial's <c>ProposeForArea</c>. -> retired in Stage 5b (math moves into LayoutProposer).</summary>
    void ProposeForArea(IntPtr output, string? outputName, Rect usableArea);

    /// <summary>Delegates to the partial's <c>IsFloatLayoutActive()</c>. -> retired in Stage 5b.</summary>
    bool IsFloatLayoutActive();

    /// <summary>Delegates to the partial's output-parametrised <c>IsFloatLayoutActive(output)</c>. -> retired in Stage 5b.</summary>
    bool IsFloatLayoutActive(IntPtr output);

    /// <summary>Delegates to the partial's <c>BuildSnapshotFor</c>. -> retired in Stage 5b.</summary>
    IReadOnlyList<WindowEntryView> BuildSnapshotFor(IntPtr output);

    /// <summary>Delegates to the partial's <c>ResolveOutputName</c>. -> retired in Stage 6 (IOutputGeometry exposes name directly).</summary>
    string? ResolveOutputName(IntPtr output);

    /// <summary>Delegates to <c>LayoutController.FocusNeighbor</c> through the partial. -> retired in Stage 5b.</summary>
    IntPtr? LayoutFocusNeighbor(
        IntPtr output,
        string? outputName,
        IntPtr current,
        FocusDirection dir,
        IReadOnlyList<WindowEntryView> snapshot);
}
