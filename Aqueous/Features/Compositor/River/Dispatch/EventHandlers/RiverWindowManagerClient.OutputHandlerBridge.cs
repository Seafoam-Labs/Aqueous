using System;
using System.Collections.Generic;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
using Aqueous.Features.State;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// PR 8.2 transient bridge — explicit-interface impl forwarding the
/// god-class's per-window and per-output state into the lifted
/// <see cref="OutputEventHandler"/>. Retired in Stage 9 when
/// <c>_windowStates</c> and <c>_outputFullscreen</c> move onto
/// <see cref="IWindowStateHost"/>.
/// </summary>
internal sealed unsafe partial class RiverWindowManagerClient : IOutputHandlerCollaborators
{
    IEnumerable<WindowStateData> IOutputHandlerCollaborators.SnapshotWindowStates()
    {
        // Snapshot to a list to avoid concurrent-modification surprises
        // during the removed-output demote loop. Allocates once per
        // output-removed event (rare).
        var snapshot = new List<WindowStateData>(_windowStates.Count);
        foreach (var kv in _windowStates)
        {
            snapshot.Add(kv.Value);
        }
        return snapshot;
    }

    void IOutputHandlerCollaborators.OnOutputRemoved(OutputProxy output, IList<WindowStateData> windowsOnOutput)
        => _windowState.OnOutputRemoved(output, windowsOnOutput);

    void IOutputHandlerCollaborators.OutputFullscreenTryRemove(IntPtr output)
        => _outputFullscreen.TryRemove(output, out _);
}
