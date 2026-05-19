using System;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// PR 8.8 Stage 8 — managed <see cref="IEventHandler"/> for the
/// <c>wl_registry</c> interface. The native dispatcher routes the
/// registry's <c>global</c>/<c>global_remove</c> events here via
/// interface-name lookup (the registry handle is tracked in
/// <c>_proxyInterface</c> at connect time).
///
/// Pass-through to the existing
/// <see cref="Aqueous.Features.Compositor.River.Connection.RegistryBinder.HandleEvent"/>
/// through the transient <see cref="IRegistryHandlerCollaborators"/>
/// bridge. Behaviour is byte-for-byte equivalent to the previous
/// <c>if (target == self._registry.Handle)</c> branch in
/// <c>ProxyDispatcher</c>.
/// </summary>
internal sealed unsafe class RegistryEventHandler : IEventHandler
{
    private readonly IRegistryHandlerCollaborators _river;
    private readonly Action<string>? _log;

    public RegistryEventHandler(IRegistryHandlerCollaborators river, Action<string>? log = null)
    {
        ArgumentNullException.ThrowIfNull(river);
        _river = river;
        _log = log;
    }

    public string InterfaceName => "wl_registry";

    public void Handle(WlEvent ev)
    {
        if (ev.ArgsPtr == IntPtr.Zero)
        {
            _log?.Invoke("RegistryEventHandler: zero ArgsPtr; opcode=" + ev.Opcode);
            return;
        }

        _river.HandleRegistryEvent(ev.Opcode, (WlArgument*)ev.ArgsPtr);
    }
}
