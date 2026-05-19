using System;
using Aqueous.Features.Bindings;
using Aqueous.Features.Compositor.River.Bindings;

namespace Aqueous.Features.Compositor.River;

// Stage 7 Shape-A bridge: RiverWindowManagerClient implements
// IKeyBindingsCollaborators explicitly, forwarding each member to the
// existing private partial-class implementations
// (RegisterAllBindings, HandleKeyBindingAction, RunCustomAction).
// Three service-seam fields (_keyBindingRegistrar / _keyBindingRouter /
// _customActionRunner) live on the god class so consumers can take
// dependencies on the public interfaces without reaching into privates.
// All four bridge members retire when the bindings partials are lifted
// in Stage 7b/8/9 — see IKeyBindingsCollaborators.cs.
internal sealed partial class RiverWindowManagerClient : IKeyBindingsCollaborators
{
    internal readonly IKeyBindingRegistrar _keyBindingRegistrar;
    internal readonly IKeyBindingRouter _keyBindingRouter;
    internal readonly ICustomActionRunner _customActionRunner;
    internal readonly IProcessLauncher _processLauncher;

    void IKeyBindingsCollaborators.RegisterAllBindings(IntPtr seatProxy)
        => RegisterAllBindings(seatProxy);

    bool IKeyBindingsCollaborators.IsBindingRegistered(IntPtr bindingProxy)
        => _keyBindings.ContainsKey(bindingProxy);

    void IKeyBindingsCollaborators.HandleKeyBindingAction(KeyBindingAction action)
        => HandleKeyBindingAction(action);

    void IKeyBindingsCollaborators.RunCustomAction(string verb)
        => RunCustomAction(verb);
}
