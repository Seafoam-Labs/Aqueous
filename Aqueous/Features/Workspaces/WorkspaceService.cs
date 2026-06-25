using System;
using Aqueous.Diagnostics;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Compositor.River.Registry;
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
    private readonly IWindowRegistry _windowRegistry;
    private readonly IOutputRegistry _outputRegistry;
    private readonly WorkspaceController _controller;

    public WorkspaceService(
        WorkspaceStore store,
        WaylandBindSiteState bindSiteState,
        IFocusService focusService,
        IManagerRequestSender managerRequestSender,
        IWindowRegistry windowRegistry,
        IOutputRegistry outputRegistry)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _bindSiteState = bindSiteState ?? throw new ArgumentNullException(nameof(bindSiteState));
        _focusService = focusService ?? throw new ArgumentNullException(nameof(focusService));
        _managerRequestSender = managerRequestSender ?? throw new ArgumentNullException(nameof(managerRequestSender));
        _windowRegistry = windowRegistry ?? throw new ArgumentNullException(nameof(windowRegistry));
        _outputRegistry = outputRegistry ?? throw new ArgumentNullException(nameof(outputRegistry));
        _controller = new WorkspaceController(this, outputs: _outputRegistry);
    }

    public Action? WorkspacesChanged { get; set; }

    // -- IWorkspaceService (facade forwarding to WorkspaceController) -------

    // Every verb that ultimately marshals a Wayland request (activate/commit/set_workspace) is
    // funnelled onto the Wayland event-pump thread via IManagerRequestSender.Post. Key-binding
    // dispatch may run off the pump thread; marshalling there races wl_display_dispatch and can hit
    // a torn-down proxy (the libwayland segfault at ~0x2c). Post runs inline when already on the
    // pump thread, so this is a no-op fast-path in that case. The bool result is now "accepted":
    // the actual switch is resolved + dispatched on the pump thread (and additionally debounced).
    public bool FocusWorkspaceByIndex(int index)
    {
        RiverLog.Write($"ws-service: accept FocusWorkspaceByIndex({index}) thread={Environment.CurrentManagedThreadId}");
        _managerRequestSender.Post(() =>
        {
            RiverLog.Write($"ws-service: pump-run FocusWorkspaceByIndex({index}) thread={Environment.CurrentManagedThreadId}");
            _controller.FocusWorkspaceByIndex(index);
        });
        return true;
    }

    public bool FocusWorkspaceUp()
    {
        _managerRequestSender.Post(() => _controller.FocusWorkspaceUp());
        return true;
    }

    public bool FocusWorkspaceDown()
    {
        _managerRequestSender.Post(() => _controller.FocusWorkspaceDown());
        return true;
    }

    public bool FocusPreviousWorkspace()
    {
        _managerRequestSender.Post(() => _controller.FocusPreviousWorkspace());
        return true;
    }

    public bool MoveFocusedToWorkspaceByIndex(int index)
    {
        _managerRequestSender.Post(() => _controller.MoveFocusedToWorkspaceByIndex(index));
        return true;
    }

    public bool MoveFocusedToWorkspaceUp()
    {
        _managerRequestSender.Post(() => _controller.MoveFocusedToWorkspaceUp());
        return true;
    }

    public bool MoveFocusedToWorkspaceDown()
    {
        _managerRequestSender.Post(() => _controller.MoveFocusedToWorkspaceDown());
        return true;
    }

    public bool MoveWorkspaceUp()
    {
        _managerRequestSender.Post(() => _controller.MoveWorkspaceUp());
        return true;
    }

    public bool MoveWorkspaceDown()
    {
        _managerRequestSender.Post(() => _controller.MoveWorkspaceDown());
        return true;
    }

    public bool MoveFocusedToOutputByName(string name)
    {
        _managerRequestSender.Post(() => _controller.MoveFocusedToOutputByName(name));
        return true;
    }

    public bool MoveFocusedToOutput(int delta)
    {
        _managerRequestSender.Post(() => _controller.MoveFocusedToOutput(delta));
        return true;
    }

    public bool FocusOutputByName(string name)
    {
        _managerRequestSender.Post(() => _controller.FocusOutputByName(name));
        return true;
    }

    public bool FocusOutput(int delta)
    {
        _managerRequestSender.Post(() => _controller.FocusOutput(delta));
        return true;
    }

    // FlushPending's only caller (OnDispatchIteration) is already on the pump thread; call directly.
    public void FlushPending() => _controller.FlushPending();

    // -- WorkspaceController.IWorkspaceHost --------------------------------

    WorkspaceStore WorkspaceController.IWorkspaceHost.Store => _store;

    void WorkspaceController.IWorkspaceHost.ActivateWorkspace(IntPtr workspace)
    {
        // Re-snapshot + re-validate on the marshalling (pump) thread, immediately before the call.
        IntPtr manager = _bindSiteState.WorkspaceManager;
        if (manager == IntPtr.Zero || workspace == IntPtr.Zero)
        {
            RiverLog.Write("activate_workspace: ext_workspace_manager_v1 not bound");
            return;
        }

        // Liveness re-check: the handle may have been reaped (a `removed` event destroyed the proxy)
        // between resolution in WorkspaceController and this marshal. Marshalling a torn-down proxy
        // segfaults inside libwayland; skipping is the correct no-op.
        if (!_store.ContainsWorkspace(workspace))
        {
            RiverLog.Write($"activate_workspace: 0x{workspace.ToString("x")} no longer live; skipping");
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

        RiverLog.Write($"activate workspace 0x{workspace.ToString("x")} on manager 0x{manager.ToString("x")} + commit");
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

        // Liveness re-check on the marshalling (pump) thread, immediately before set_workspace: the
        // destination handle may have been reaped between resolution and this marshal.
        if (!_store.ContainsWorkspace(workspace))
        {
            RiverLog.Write($"move_to_workspace: 0x{workspace.ToString("x")} no longer live; skipping");
            return false;
        }

        // river_window_v1.set_workspace (opcode 24); the workspace handle is the single object arg.
        WaylandInterop.wl_proxy_marshal_flags(
            focused, RiverProtocolOpcodes.Window.SetWorkspace, IntPtr.Zero, 0, 0,
            workspace, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

        // Mirror the assignment into our per-window state in lock-step with the request so the
        // layout proposer can hide this window when its destination workspace is not the active one
        // (the fix for the half-size symptom: an off-workspace window must not enter the tiled
        // snapshot and steal a master/stack slot).
        if (_windowRegistry.TryGet(focused, out var entry))
        {
            entry.Workspace = workspace;
        }

        RiverLog.Write($"set_workspace window 0x{focused.ToString("x")} -> 0x{workspace.ToString("x")}");
        return true;
    }

    void WorkspaceController.IWorkspaceHost.AfterChange()
    {
        _managerRequestSender.ScheduleManage();
        WorkspacesChanged?.Invoke();
    }
}
