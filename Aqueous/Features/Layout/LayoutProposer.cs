using System;
using System.Collections.Generic;
using Aqueous.Features.Compositor.River.Layout;

namespace Aqueous.Features.Layout;

/// <summary>
/// Stage 5 facade for <see cref="ILayoutProposer"/>: thin delegating
/// implementation that routes every call back into the partial
/// <c>RiverWindowManagerClient.LayoutProposer</c> via
/// <see cref="ILayoutProposerCollaborators"/>. The literal migration
/// of the 762-line proposer math + its private state
/// (<c>_outputFullscreen</c>, <c>_prevFullscreenHandles</c>,
/// <c>_windowStates</c> access, the engine driver) is intentionally
/// deferred to Stage 5b — see <see cref="ILayoutProposer"/>'s XML
/// doc for the rationale.
///
/// <para>
/// Pump-thread only. Mirrors the existing partial's threading
/// contract exactly; no new locks or queues are introduced here.
/// </para>
/// </summary>
internal sealed class LayoutProposer : ILayoutProposer
{
    private readonly ILayoutProposerCollaborators _river;

    public LayoutProposer(ILayoutProposerCollaborators river)
    {
        ArgumentNullException.ThrowIfNull(river);
        _river = river;
    }

    public void ProposeForArea(IntPtr output, string? outputName, Rect usableArea) =>
        _river.ProposeForArea(output, outputName, usableArea);

    public bool IsFloatLayoutActive() => _river.IsFloatLayoutActive();

    public bool IsFloatLayoutActive(IntPtr output) => _river.IsFloatLayoutActive(output);

    public IReadOnlyList<WindowEntryView> BuildSnapshotFor(IntPtr output) =>
        _river.BuildSnapshotFor(output);

    public string? ResolveOutputName(IntPtr output) => _river.ResolveOutputName(output);

    public IntPtr? LayoutFocusNeighbor(
        IntPtr output,
        string? outputName,
        IntPtr current,
        FocusDirection dir,
        IReadOnlyList<WindowEntryView> snapshot) =>
        _river.LayoutFocusNeighbor(output, outputName, current, dir, snapshot);
}
