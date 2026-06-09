using System;
using Aqueous.Diagnostics;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Focus;
using Aqueous.Features.Layout;

namespace Aqueous.Features.Workspaces;

/// <summary>
/// Implements both <see cref="IWorkspaceService"/> (the public, niri-shaped surface used by
/// keybindings / IPC / tests) and <see cref="WorkspaceController.IWorkspaceHost"/> (the low-level
/// protocol side-effects) driven by an internally-owned <see cref="WorkspaceController"/>.
/// <para>
/// Switching marshals <c>ext_workspace_handle_v1.activate</c> + <c>ext_workspace_manager_v1.commit</c>;
/// "send to workspace" marshals <c>river_window_v1.set_workspace</c> on the focused window.
/// Pump-thread only.
/// </para>
/// </summary>
internal sealed unsafe class WorkspaceService : IWorkspaceService, WorkspaceController.IWorkspaceHost
{
    private readonly WorkspaceStore _store;
    private readonly WaylandBindSiteState _bindSiteState;
    private readonly IFocusService _focusService;
    private readonly IManagerRequestSender _managerRequestSender;
    private readonly WorkspaceController _controller;

    public WorkspaceService(
        WorkspaceStore store,
        WaylandBindSiteState bindSiteState,
        IFocusService focusService,
        IManagerRequestSender managerRequestSender)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _bindSiteState = bindSiteState ?? throw new ArgumentNullException(nameof(bindSiteState));
        _focusService = focusService ?? throw new ArgumentNullException(nameof(focusService));
        _managerRequestSender = managerRequestSender ?? throw new ArgumentNullException(nameof(managerRequestSender));
        _controller = new WorkspaceController(this);
    }

    public Action? WorkspacesChanged { get; set; }

    // -- IWorkspaceService (facade forwarding to WorkspaceController) -------

    public bool FocusWorkspaceByIndex(int index) => _controller.FocusWorkspaceByIndex(index);
    public bool FocusWorkspaceUp() => _controller.FocusWorkspaceUp();
    public bool FocusWorkspaceDown() => _controller.FocusWorkspaceDown();
    public bool FocusPreviousWorkspace() => _controller.FocusPreviousWorkspace();
    public bool MoveFocusedToWorkspaceByIndex(int index) => _controller.MoveFocusedToWorkspaceByIndex(index);
    public bool MoveFocusedToWorkspaceUp() => _controller.MoveFocusedToWorkspaceUp();
    public bool MoveFocusedToWorkspaceDown() => _controller.MoveFocusedToWorkspaceDown();
    public bool MoveWorkspaceUp() => _controller.MoveWorkspaceUp();
    public bool MoveWorkspaceDown() => _controller.MoveWorkspaceDown();

    // -- WorkspaceController.IWorkspaceHost --------------------------------

    WorkspaceStore WorkspaceController.IWorkspaceHost.Store => _store;

    void WorkspaceController.IWorkspaceHost.ActivateWorkspace(IntPtr workspace)
    {
        IntPtr manager = _bindSiteState.WorkspaceManager;
        if (manager == IntPtr.Zero || workspace == IntPtr.Zero)
        {
            RiverLog.Write("activate_workspace: ext_workspace_manager_v1 not bound");
            return;
        }

        // ext_workspace_handle_v1.activate (opcode 1).
        WaylandInterop.wl_proxy_marshal_flags(
            workspace, RiverProtocolOpcodes.ExtWorkspaceHandle.Activate, IntPtr.Zero, 0, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

        // ext_workspace_manager_v1.commit (opcode 0).
        WaylandInterop.wl_proxy_marshal_flags(
            manager, RiverProtocolOpcodes.ExtWorkspaceManager.Commit, IntPtr.Zero, 0, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

        RiverLog.Write($"activate workspace 0x{workspace.ToString("x")} + commit");
    }

    bool WorkspaceController.IWorkspaceHost.MoveFocusedToWorkspace(IntPtr workspace)
    {
        if (workspace == IntPtr.Zero)
        {
            return false;
        }

        if (!_focusService.TryGetFocusedAlive(out var focused))
        {
            RiverLog.Write("move_to_workspace: no focused window");
            return false;
        }

        // river_window_v1.set_workspace (opcode 24); the workspace handle is the single object arg.
        WaylandInterop.wl_proxy_marshal_flags(
            focused, RiverProtocolOpcodes.Window.SetWorkspace, IntPtr.Zero, 0, 0,
            workspace, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

        RiverLog.Write($"set_workspace window 0x{focused.ToString("x")} -> 0x{workspace.ToString("x")}");
        return true;
    }

    void WorkspaceController.IWorkspaceHost.AfterChange()
    {
        _managerRequestSender.ScheduleManage();
        WorkspacesChanged?.Invoke();
    }
}
