using System;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Bindings;

namespace Aqueous.Features.Bindings;

/// <summary>
/// Stage 7 Shape-A façade: forwards <see cref="IKeyBindingRouter.Handle"/>
/// to the existing god-class action table via
/// <see cref="IKeyBindingsCollaborators"/>. Literal lift of the 282-line
/// action router (tag arithmetic, ActionTable lambda dispatch, spawn
/// helpers, config reload) is deferred — see the bridge XML-doc.
/// </summary>
internal sealed class KeyBindingRouter : IKeyBindingRouter
{
    private readonly IKeyBindingsCollaborators _river;

    public KeyBindingRouter(IKeyBindingsCollaborators river)
    {
        _river = river ?? throw new ArgumentNullException(nameof(river));
    }

    public void Handle(KeyBindingAction action) => _river.HandleKeyBindingAction(action);
}
