using System;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// PR 8.8 Stage 8 — managed <see cref="IEventHandler"/> for the
/// <c>river_xkb_binding_v1</c> interface (per-binding proxies declared
/// by <c>KeyBindingRegistrar</c>). Routes here via interface-name lookup;
/// each per-key proxy is tracked in <c>_proxyInterface</c> at declare time.
///
/// Pass-through to the existing <c>OnKeyBindingEvent</c> partial through
/// the transient <see cref="IKeyBindingHandlerCollaborators"/> bridge.
/// Behaviour is byte-for-byte equivalent to the previous
/// <c>else if (self._keyBindingRegistrar.IsRegistered(target))</c> branch
/// in <c>ProxyDispatcher</c>.
/// </summary>
internal sealed unsafe class KeyBindingEventHandler : IEventHandler
{
    private readonly IKeyBindingHandlerCollaborators _river;
    private readonly Action<string>? _log;

    public KeyBindingEventHandler(IKeyBindingHandlerCollaborators river, Action<string>? log = null)
    {
        ArgumentNullException.ThrowIfNull(river);
        _river = river;
        _log = log;
    }

    public string InterfaceName => "river_xkb_binding_v1";

    public void Handle(WlEvent ev)
    {
        if (ev.Target == IntPtr.Zero)
        {
            _log?.Invoke("KeyBindingEventHandler: zero target; opcode=" + ev.Opcode);
            return;
        }

        _river.HandleKeyBindingEvent(
            ev.Target,
            ev.Opcode,
            ev.ArgsPtr == IntPtr.Zero ? null : (WlArgument*)ev.ArgsPtr);
    }
}
