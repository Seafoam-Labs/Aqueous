using System;
namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
/// <summary>
/// Managed <see cref="IEventHandler"/> for the
/// <c>river_super_key_binding_v1</c> proxy that fires
/// <c>pressed</c>/<c>released</c> opcodes (today triggers a dbus-send
/// fire-and-forget to toggle the Aqueous start menu).
///
/// PR 9.4 Stage 9 retires the transient
/// <c>ISuperKeyBindingHandlerCollaborators</c> bridge and consumes
/// <see cref="RiverWindowManagerClient"/> directly via its
/// <c>HandleSuperKeyBindingEvent</c> accessor — same pattern PR 9.3
/// established for <c>RegistryEventHandler</c>. The body still lives in
/// the <c>OnSuperKeyBindingEvent</c> partial; final lift to
/// <see cref="Aqueous.Features.Bindings.IProcessLauncher"/> is Stage 9
/// final cleanup.
/// </summary>
internal sealed unsafe class SuperKeyBindingEventHandler : IEventHandler
{
    private readonly RiverWindowManagerClient _client;
    private readonly Action<string>? _log;
    public SuperKeyBindingEventHandler(
        RiverWindowManagerClient client,
        Action<string>? log = null)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
        _log = log;
    }
    public string InterfaceName => "river_super_key_binding_v1";
    public void Handle(WlEvent ev)
    {
        var args = ev.ArgsPtr == IntPtr.Zero ? null : (WlArgument*)ev.ArgsPtr;
        _client.HandleSuperKeyBindingEvent(ev.Opcode, args);
    }
}
