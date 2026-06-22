using System;

namespace Aqueous.Features.Workspaces;

/// <summary>
/// High-level, niri-shaped workspace operations exposed to keybindings / IPC / tests. Workspaces
/// are exclusive: a window lives on exactly one workspace and exactly one workspace is active per
/// output, so the verb set mirrors niri (<c>focus-workspace</c>, <c>focus-workspace-up/down</c>,
/// <c>move-window-to-workspace</c>, …) rather than the multi-select tag vocabulary.
/// <para>
/// Switching is client-driven: the implementation issues <c>ext_workspace_handle_v1.activate</c>
/// followed by <c>ext_workspace_manager_v1.commit</c>; visibility flips natively in the compositor.
/// "Send to workspace" is carried by <c>river_window_v1.set_workspace</c> because
/// <c>ext-workspace-v1</c> has no window concept. Indices are 1-based to match the keymap digits.
/// </para>
/// </summary>
public interface IWorkspaceService
{
    /// <summary>Focus the workspace at <paramref name="index"/> (1-based) in the current group.</summary>
    bool FocusWorkspaceByIndex(int index);

    /// <summary>Focus the workspace before the active one in the current group.</summary>
    bool FocusWorkspaceUp();

    /// <summary>Focus the workspace after the active one in the current group.</summary>
    bool FocusWorkspaceDown();

    /// <summary>Focus the workspace that was active before the most recent switch.</summary>
    bool FocusPreviousWorkspace();

    /// <summary>Move the focused window to the workspace at <paramref name="index"/> (1-based).</summary>
    bool MoveFocusedToWorkspaceByIndex(int index);

    /// <summary>Move the focused window to the workspace before the active one.</summary>
    bool MoveFocusedToWorkspaceUp();

    /// <summary>Move the focused window to the workspace after the active one.</summary>
    bool MoveFocusedToWorkspaceDown();

    /// <summary>Reorder the active workspace earlier in the current group's list.</summary>
    bool MoveWorkspaceUp();

    /// <summary>Reorder the active workspace later in the current group's list.</summary>
    bool MoveWorkspaceDown();

    /// <summary>Move the focused window to the active workspace of the output addressed by <paramref name="name"/>.</summary>
    bool MoveFocusedToOutputByName(string name);

    /// <summary>Move the focused window to the active workspace of the output <paramref name="delta"/> steps away.</summary>
    bool MoveFocusedToOutput(int delta);

    /// <summary>Focus the active workspace of the output addressed by <paramref name="name"/>.</summary>
    bool FocusOutputByName(string name);

    /// <summary>Focus the active workspace of the output <paramref name="delta"/> steps away.</summary>
    bool FocusOutput(int delta);

    /// <summary>
    /// Dispatch a workspace switch that was coalesced by the rapid-switch debounce once its window
    /// has elapsed. Must be called from the Wayland event-pump thread, once per dispatch iteration.
    /// </summary>
    void FlushPending();

    /// <summary>Optional sink invoked after every successful workspace mutation (bar / IPC hook).</summary>
    Action? WorkspacesChanged { get; set; }
}
