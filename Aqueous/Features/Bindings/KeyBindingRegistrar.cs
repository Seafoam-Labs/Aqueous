using System;
using Aqueous.Features.Compositor.River.Bindings;

namespace Aqueous.Features.Bindings;

/// <summary>
/// Stage 7 Shape-A façade: forwards <see cref="IKeyBindingRegistrar"/>
/// calls to the existing god-class implementation via
/// <see cref="IKeyBindingsCollaborators"/>. The actual
/// <c>_keyBindings</c>/<c>_customBindingActions</c> dictionaries and the
/// xkb P/Invoke chord declaration still live on
/// <c>RiverWindowManagerClient</c>.
/// </summary>
internal sealed class KeyBindingRegistrar : IKeyBindingRegistrar
{
    private readonly IKeyBindingsCollaborators _river;

    public KeyBindingRegistrar(IKeyBindingsCollaborators river)
    {
        _river = river ?? throw new ArgumentNullException(nameof(river));
    }

    public void RegisterAllBindings(IntPtr seatProxy) => _river.RegisterAllBindings(seatProxy);

    public bool IsRegistered(IntPtr bindingProxy) => _river.IsBindingRegistered(bindingProxy);
}
