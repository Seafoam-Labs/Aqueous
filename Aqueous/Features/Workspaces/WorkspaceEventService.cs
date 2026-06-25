using System;
using Aqueous.Diagnostics;
using Aqueous.Features.Bindings;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Compositor.River.Dispatch;

namespace Aqueous.Features.Workspaces;

/// <summary>
/// Mirrors <c>ext-workspace-v1</c> protocol events into the <see cref="WorkspaceStore"/>. Handles
/// the manager, group-handle and workspace-handle interfaces; newly-created group/workspace
/// objects (delivered as <c>new_id</c> args on manager events) get a dispatcher installed and their
/// interface tracked so their own events route back here. Pump-thread only.
/// </summary>
internal sealed unsafe class WorkspaceEventService
{
    private readonly WorkspaceStore _store;
    private readonly WaylandBindSiteState _bindSiteState;
    private readonly KeyBindingsRegistry _keyBindingsRegistry;

    public WorkspaceEventService(
        WorkspaceStore store,
        WaylandBindSiteState bindSiteState,
        KeyBindingsRegistry keyBindingsRegistry)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _bindSiteState = bindSiteState ?? throw new ArgumentNullException(nameof(bindSiteState));
        _keyBindingsRegistry = keyBindingsRegistry ?? throw new ArgumentNullException(nameof(keyBindingsRegistry));
    }

    private static IntPtr Dispatcher =>
        (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&NativeCallbackEntry.Dispatch;

    private void Attach(IntPtr proxy, string interfaceName)
    {
        if (proxy == IntPtr.Zero)
        {
            return;
        }

        WaylandInterop.wl_proxy_add_dispatcher(proxy, Dispatcher, _keyBindingsRegistry.SelfHandlePtr, IntPtr.Zero);
        _bindSiteState.TrackProxyInterface(proxy, interfaceName);
    }

    /// <summary>
    /// Finalize a reaped <c>ext_workspace_*</c> handle: marshal its <c>destroy</c> request (which
    /// also frees the proxy via <see cref="WaylandInterop.WL_MARSHAL_FLAG_DESTROY"/>, per the
    /// protocol's destructor semantics) and drop it from the proxy → interface tracker so no further
    /// events route to the dead object.
    /// </summary>
    private void FinalizeHandle(IntPtr proxy, uint destroyOpcode)
    {
        if (proxy == IntPtr.Zero)
        {
            return;
        }

        WaylandInterop.wl_proxy_marshal_flags(
            proxy, destroyOpcode, IntPtr.Zero, 0, WaylandInterop.WL_MARSHAL_FLAG_DESTROY,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        _bindSiteState.UntrackProxyInterface(proxy);
    }

    public void HandleManagerEvent(WlEvent ev)
    {
        var args = (WlArgument*)ev.ArgsPtr;
        switch (ev.Opcode)
        {
            case RiverProtocolOpcodes.ExtWorkspaceManager.WorkspaceGroup:
                if (ev.ArgCount < 1) return;
            {
                IntPtr group = args[0].o;
                _store.AddGroup(group);
                Attach(group, "ext_workspace_group_handle_v1");
                RiverLog.Write($"+ workspace_group 0x{group.ToString("x")}");
            }
                break;
            case RiverProtocolOpcodes.ExtWorkspaceManager.Workspace:
                if (ev.ArgCount < 1) return;
            {
                IntPtr workspace = args[0].o;
                _store.AddWorkspace(workspace);
                Attach(workspace, "ext_workspace_handle_v1");
                RiverLog.Write($"+ workspace 0x{workspace.ToString("x")}");
            }
                break;
            case RiverProtocolOpcodes.ExtWorkspaceManager.Done:
                _store.NotifyChanged();
                break;
            case RiverProtocolOpcodes.ExtWorkspaceManager.Finished:
                _store.Clear();
                _bindSiteState.WorkspaceManager = IntPtr.Zero;
                break;
        }
    }

    public void HandleGroupEvent(WlEvent ev)
    {
        var args = (WlArgument*)ev.ArgsPtr;
        IntPtr group = ev.Target;
        switch (ev.Opcode)
        {
            case RiverProtocolOpcodes.ExtWorkspaceGroup.WorkspaceEnter:
                if (ev.ArgCount < 1)
                {
                    return;
                }

                _store.EnterGroup(group, args[0].o);
                break;
            case RiverProtocolOpcodes.ExtWorkspaceGroup.WorkspaceLeave:
                if (ev.ArgCount < 1)
                {
                    return;
                }

                _store.LeaveGroup(group, args[0].o);
                break;
            case RiverProtocolOpcodes.ExtWorkspaceGroup.Removed:
                _store.RemoveGroup(group);
                FinalizeHandle(group, RiverProtocolOpcodes.ExtWorkspaceGroup.Destroy);
                break;
            case RiverProtocolOpcodes.ExtWorkspaceGroup.OutputEnter:
                if (ev.ArgCount < 1)
                {
                    return;
                }

                _store.SetGroupOutput(group, args[0].o);
                break;
            case RiverProtocolOpcodes.ExtWorkspaceGroup.OutputLeave:
                if (ev.ArgCount < 1)
                {
                    return;
                }

                _store.ClearGroupOutput(group, args[0].o);
                break;
        }
    }

    public void HandleWorkspaceEvent(WlEvent ev)
    {
        var args = (WlArgument*)ev.ArgsPtr;
        IntPtr workspace = ev.Target;
        switch (ev.Opcode)
        {
            case RiverProtocolOpcodes.ExtWorkspaceHandle.Name:
                if (ev.ArgCount < 1) return;
                if (_store.TryGetWorkspace(workspace, out var w))
                {
                    w.Name = WlArgumentDecoder.GetString(ev.ArgsPtr, 0);
                }

                break;
            case RiverProtocolOpcodes.ExtWorkspaceHandle.Coordinates:
                if (ev.ArgCount < 1) return;
                _store.SetCoordinates(workspace, WlArgumentDecoder.GetUintArray(ev.ArgsPtr, 0));
                break;
            case RiverProtocolOpcodes.ExtWorkspaceHandle.State:
                if (ev.ArgCount < 1) return;
            {
                uint state = args[0].u;
                bool active = (state & RiverProtocolOpcodes.ExtWorkspaceHandle.StateActive) != 0;
                bool urgent = (state & RiverProtocolOpcodes.ExtWorkspaceHandle.StateUrgent) != 0;
                _store.SetState(workspace, active, urgent);
            }
                break;
            case RiverProtocolOpcodes.ExtWorkspaceHandle.Removed:
                _store.RemoveWorkspace(workspace);
                FinalizeHandle(workspace, RiverProtocolOpcodes.ExtWorkspaceHandle.Destroy);
                break;
        }
    }
}
