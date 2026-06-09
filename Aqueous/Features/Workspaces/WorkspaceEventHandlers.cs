using System;
using Aqueous.Features.Compositor.River.Dispatch;

namespace Aqueous.Features.Workspaces;

/// <summary>
/// <see cref="IEventHandler"/> for <c>ext_workspace_manager_v1</c>; forwards to
/// <see cref="WorkspaceEventService"/>.
/// </summary>
internal sealed class ExtWorkspaceManagerEventHandler : IEventHandler
{
    private readonly WorkspaceEventService _service;

    public ExtWorkspaceManagerEventHandler(WorkspaceEventService service)
        => _service = service ?? throw new ArgumentNullException(nameof(service));

    public string InterfaceName => "ext_workspace_manager_v1";

    public void Handle(WlEvent ev) => _service.HandleManagerEvent(ev);
}

/// <summary>
/// <see cref="IEventHandler"/> for <c>ext_workspace_group_handle_v1</c>; forwards to
/// <see cref="WorkspaceEventService"/>.
/// </summary>
internal sealed class ExtWorkspaceGroupEventHandler : IEventHandler
{
    private readonly WorkspaceEventService _service;

    public ExtWorkspaceGroupEventHandler(WorkspaceEventService service)
        => _service = service ?? throw new ArgumentNullException(nameof(service));

    public string InterfaceName => "ext_workspace_group_handle_v1";

    public void Handle(WlEvent ev) => _service.HandleGroupEvent(ev);
}

/// <summary>
/// <see cref="IEventHandler"/> for <c>ext_workspace_handle_v1</c>; forwards to
/// <see cref="WorkspaceEventService"/>.
/// </summary>
internal sealed class ExtWorkspaceHandleEventHandler : IEventHandler
{
    private readonly WorkspaceEventService _service;

    public ExtWorkspaceHandleEventHandler(WorkspaceEventService service)
        => _service = service ?? throw new ArgumentNullException(nameof(service));

    public string InterfaceName => "ext_workspace_handle_v1";

    public void Handle(WlEvent ev) => _service.HandleWorkspaceEvent(ev);
}
