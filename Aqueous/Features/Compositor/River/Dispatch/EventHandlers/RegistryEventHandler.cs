using System;
using Aqueous.Features.Compositor.River.Connection;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// Managed <see cref="IEventHandler"/> for the <c>wl_registry</c> interface. The native dispatcher
/// routes the registry's <c>global</c>/<c>global_remove</c> events here via interface-name lookup
/// (the registry handle is tracked in <c>_proxyInterface</c> at connect time). retires the
/// transient <c>IRegistryHandlerCollaborators</c> bridge and consumes <see cref="RegistryBinder"/>
/// directly — it has always been a self-contained class with no class coupling, so the bridge was
/// indirection-without-purpose. Behaviour is byte-for-byte equivalent to the previous bridge call.
/// confirmed zero class coupling — the ctor takes only <see cref="RegistryBinder"/> plus an
/// optional log sink, and the body has no <c>RiverWindowManagerClient</c> reference. No cutover
/// required; and the matching ctor-shape pin alongside the other handlers.
/// </summary>
internal sealed unsafe class RegistryEventHandler : IEventHandler
{
    private readonly RegistryBinder _binder;
    private readonly Action<string>? _log;

    public RegistryEventHandler(RegistryBinder binder, Action<string>? log = null)
    {
        ArgumentNullException.ThrowIfNull(binder);
        _binder = binder;
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

        _binder.HandleEvent(ev.Opcode, (WlArgument*)ev.ArgsPtr);
    }
}
