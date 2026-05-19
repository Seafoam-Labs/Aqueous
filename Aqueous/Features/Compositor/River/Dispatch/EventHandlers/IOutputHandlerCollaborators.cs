using System;
using System.Collections.Generic;
using Aqueous.Features.State;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// PR 8.2 transient bridge — exposes the slice of god-class state that
/// the lifted <see cref="OutputEventHandler"/> needs to drive the
/// <c>river_output_v1::removed</c> demote/cleanup sequence.
///
/// Each member is XML-doc'd with the stage that retires it. Implemented
/// only by <c>RiverWindowManagerClient</c>; will be deleted in Stage 9
/// when the god class collapses.
/// </summary>
internal interface IOutputHandlerCollaborators
{
    /// <summary>Snapshot of the per-window state map, used to find windows pinned to the removed output.
    /// -> retired in Stage 9 once <c>_windowStates</c> moves into <see cref="IWindowStateHost"/>.</summary>
    IEnumerable<WindowStateData> SnapshotWindowStates();

    /// <summary>Forward output removal to the window-state controller.
    /// -> retired in Stage 9.</summary>
    void OnOutputRemoved(OutputProxy output, IList<WindowStateData> windowsOnOutput);

    /// <summary>Drop the per-output fullscreen entry for <paramref name="output"/>.
    /// -> retired in Stage 9 once <c>_outputFullscreen</c> moves into <see cref="IWindowStateHost"/>.</summary>
    void OutputFullscreenTryRemove(IntPtr output);
}
