using System;
using System.Collections.Generic;
using Aqueous.Features.Layout;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Stage 5 bridge: explicit implementation of
/// <see cref="Aqueous.Features.Compositor.River.Layout.ILayoutProposerCollaborators"/>
/// — each member is a 1-line delegate to the existing private method on
/// the <c>LayoutProposer</c> partial. Lets the new
/// <see cref="Aqueous.Features.Layout.LayoutProposer"/> facade route
/// calls back into the partial without per-call-site changes elsewhere
/// in the codebase.
///
/// <para>
/// Retired in Stage 5b (when the 762-line proposer math moves into
/// <c>LayoutProposer</c>) or in Stage 8 at the latest.
/// </para>
/// </summary>
internal sealed unsafe partial class RiverWindowManagerClient :
    Aqueous.Features.Compositor.River.Layout.ILayoutProposerCollaborators
{
    void Aqueous.Features.Compositor.River.Layout.ILayoutProposerCollaborators.ProposeForArea(
        IntPtr output, string? outputName, Rect usableArea) =>
        ProposeForArea(output, outputName, usableArea);

    bool Aqueous.Features.Compositor.River.Layout.ILayoutProposerCollaborators.IsFloatLayoutActive() =>
        IsFloatLayoutActive();

    bool Aqueous.Features.Compositor.River.Layout.ILayoutProposerCollaborators.IsFloatLayoutActive(IntPtr output) =>
        IsFloatLayoutActive(output);

    IReadOnlyList<WindowEntryView>
        Aqueous.Features.Compositor.River.Layout.ILayoutProposerCollaborators.BuildSnapshotFor(IntPtr output) =>
        BuildSnapshotFor(output);

    string? Aqueous.Features.Compositor.River.Layout.ILayoutProposerCollaborators.ResolveOutputName(IntPtr output) =>
        ResolveOutputName(output);

    IntPtr? Aqueous.Features.Compositor.River.Layout.ILayoutProposerCollaborators.LayoutFocusNeighbor(
        IntPtr output, string? outputName, IntPtr current, FocusDirection dir, IReadOnlyList<WindowEntryView> snapshot) =>
        _layoutController.FocusNeighbor(output, outputName, current, dir, snapshot);
}
