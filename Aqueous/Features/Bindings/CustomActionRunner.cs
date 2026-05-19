using System;
using Aqueous.Features.Compositor.River.Bindings;

namespace Aqueous.Features.Bindings;

/// <summary>
/// Stage 7 Shape-A façade: forwards <see cref="ICustomActionRunner.Run"/>
/// to the existing god-class implementation via
/// <see cref="IKeyBindingsCollaborators"/>. Literal lift deferred until
/// the god class's verb dispatch dependencies (layout controller,
/// window-state host, scratchpad registry, focus helpers) are themselves
/// extracted.
/// </summary>
internal sealed class CustomActionRunner : ICustomActionRunner
{
    private readonly IKeyBindingsCollaborators _river;

    public CustomActionRunner(IKeyBindingsCollaborators river)
    {
        _river = river ?? throw new ArgumentNullException(nameof(river));
    }

    public void Run(string verb)
    {
        if (verb is null)
        {
            return;
        }
        _river.RunCustomAction(verb);
    }
}
