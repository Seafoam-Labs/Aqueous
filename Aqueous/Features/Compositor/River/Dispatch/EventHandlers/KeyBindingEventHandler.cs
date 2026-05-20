using System;
using Aqueous.Features.Bindings;
namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
/// <summary>
/// Managed <see cref="IEventHandler"/> for the
/// <c>river_xkb_binding_v1</c> interface (per-binding proxies declared
/// by <c>KeyBindingRegistrar</c>). Routes here via interface-name lookup;
/// each per-key proxy is tracked in <c>_proxyInterface</c> at declare time.
///
/// PR 9.4 Stage 9 retires the transient
/// <c>IKeyBindingHandlerCollaborators</c> bridge and consumes
/// <see cref="RiverWindowManagerClient"/> directly via its
/// <c>HandleKeyBindingEvent</c> accessor (same pattern PR 9.3 used for
/// <c>RegistryEventHandler</c>). The body still lives in the
/// <c>OnKeyBindingEvent</c> partial because it accesses god-class
/// privates (<c>_keyBindings</c>, <c>_customBindingActions</c>,
/// <c>HandleKeyBindingAction</c>, <c>RunCustomAction</c>) — final lift
/// to <see cref="Aqueous.Features.Bindings.IKeyBindingRouter"/> is
/// Stage 9 cleanup.
/// </summary>
internal sealed unsafe class KeyBindingEventHandler : IEventHandler
{
    private readonly KeyBindingRegistrar _registrar;
    private readonly Action<string>? _log;
    // PR 9.12 §2.13 Step 6: ctor no longer takes RiverWindowManagerClient;
    // the handler dispatches directly to the top-level KeyBindingRegistrar
    // singleton (which owns HandleKeyBindingEvent since the partial drain).
    public KeyBindingEventHandler(KeyBindingRegistrar registrar, Action<string>? log = null)
    {
        ArgumentNullException.ThrowIfNull(registrar);
        _registrar = registrar;
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
        _registrar.HandleKeyBindingEvent(
            ev.Target,
            ev.Opcode,
            ev.ArgsPtr == IntPtr.Zero ? null : (WlArgument*)ev.ArgsPtr);
    }
}
