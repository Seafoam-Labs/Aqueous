using System;
using System.Collections.Generic;
using Aqueous.Features.Compositor.River;
namespace Aqueous.Features.Layout;
/// <summary>
/// Stage 5 facade for <see cref="ILayoutProposer"/>: thin delegating
/// implementation that routes every call back into the partial
/// <c>RiverWindowManagerClient.LayoutProposer</c>. PR 9.8 retired the
/// <c>ILayoutProposerCollaborators</c> bridge — consumers now hold the
/// god class directly via internal pass-through accessors. Stage 9
/// final cleanup will collapse this facade once the 762-line proposer
/// body moves out of the partial.
///
/// <para>
/// Pump-thread only. Mirrors the existing partial's threading
/// contract exactly; no new locks or queues are introduced here.
/// </para>
/// </summary>
internal sealed class LayoutProposer : ILayoutProposer
{
    private readonly RiverWindowManagerClient _river;
    public LayoutProposer(RiverWindowManagerClient river)
    {
        ArgumentNullException.ThrowIfNull(river);
        _river = river;
    }
    public void ProposeForArea(IntPtr output, string? outputName, Rect usableArea) =>
        _river.ProposeForAreaForwarding(output, outputName, usableArea);
    public bool IsFloatLayoutActive() => _river.IsFloatLayoutActiveForwarding();
    public bool IsFloatLayoutActive(IntPtr output) => _river.IsFloatLayoutActiveForwarding(output);
    public IReadOnlyList<WindowEntryView> BuildSnapshotFor(IntPtr output) =>
        _river.BuildSnapshotForForwarding(output);
    public string? ResolveOutputName(IntPtr output) => _river.ResolveOutputNameForwarding(output);
    public IntPtr? LayoutFocusNeighbor(
        IntPtr output,
        string? outputName,
        IntPtr current,
        FocusDirection dir,
        IReadOnlyList<WindowEntryView> snapshot) =>
        _river.LayoutFocusNeighborForwarding(output, outputName, current, dir, snapshot);
}
