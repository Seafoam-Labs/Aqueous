using System;
using Aqueous.Features.Compositor.River;
namespace Aqueous.Features.Bindings;

/// <summary>
/// PR 9.9 (Stage 9): consumes <see cref="RiverWindowManagerClient"/>
/// directly via pass-through accessors (was Stage 7 Shape-A bridge).
/// The 245-line registrar body still lives on the god class as a
/// partial; full literal lift is deferred per the parent plan.
/// </summary>
internal sealed class KeyBindingRegistrar : IKeyBindingRegistrar
{
    private readonly RiverWindowManagerClient _river;

    public KeyBindingRegistrar(RiverWindowManagerClient river)
    {
        _river = river ?? throw new ArgumentNullException(nameof(river));
    }

    public void RegisterAllBindings(IntPtr seatProxy) => _river.RegisterAllBindingsForwarding(seatProxy);
    public bool IsRegistered(IntPtr bindingProxy) => _river.IsBindingRegisteredForwarding(bindingProxy);
}
