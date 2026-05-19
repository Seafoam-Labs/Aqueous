using System;
using Aqueous.Features.Compositor.River;

namespace Aqueous.Features.Compositor.River.Bindings;

/// <summary>
/// Stage 7 transient collaborator bridge for the bindings trio
/// (<c>IKeyBindingRegistrar</c> / <c>IKeyBindingRouter</c> /
/// <c>ICustomActionRunner</c>). Each member is documented with the
/// stage that retires it; literal lift of the 671-line bindings
/// partials is deferred to a follow-up because they reference
/// ~15 god-class privates (layout config, layout controller,
/// window-state host, tag controller, focus helpers, xkb proxies,
/// scratchpad registry, input daemon, P/Invoke), which cannot be
/// migrated safely without a manual smoke run against River.
/// </summary>
internal interface IKeyBindingsCollaborators
{
    /// <summary>Delegate to god-class <c>RegisterAllBindings</c>. -&gt; retired in Stage 7b/9.</summary>
    void RegisterAllBindings(IntPtr seatProxy);

    /// <summary>True if the binding proxy is registered. -&gt; retired in Stage 7b/9.</summary>
    bool IsBindingRegistered(IntPtr bindingProxy);

    /// <summary>Delegate to god-class <c>HandleKeyBindingAction</c>. -&gt; retired in Stage 8/9.</summary>
    void HandleKeyBindingAction(KeyBindingAction action);

    /// <summary>Delegate to god-class <c>RunCustomAction</c>. -&gt; retired in Stage 8/9.</summary>
    void RunCustomAction(string verb);
}
