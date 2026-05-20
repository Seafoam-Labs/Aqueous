using System;
using Aqueous.Features.Bindings;
namespace Aqueous.Features.Compositor.River;

// PR 9.9 (Stage 9): pass-through accessors for the bindings trio,
// replacing the retired IKeyBindingsCollaborators bridge. These mirror
// the Shape-A pattern PRs 9.3–9.8 used: thin internal methods/properties
// on the god class that forward to the existing private partial bodies
// so KeyBindingRegistrar / KeyBindingRouter / CustomActionRunner can
// consume RiverWindowManagerClient directly via DI.
internal sealed partial class RiverWindowManagerClient
{
    internal readonly IKeyBindingRegistrar _keyBindingRegistrar;
    internal readonly IKeyBindingRouter _keyBindingRouter;
    internal readonly ICustomActionRunner _customActionRunner;
    internal readonly IProcessLauncher _processLauncher;

    internal void RegisterAllBindingsForwarding(IntPtr seatProxy)
        => RegisterAllBindings(seatProxy);

    internal bool IsBindingRegisteredForwarding(IntPtr bindingProxy)
        => _keyBindings.ContainsKey(bindingProxy);

    // PR 9.9 (Stage 9): the literal bodies of HandleKeyBindingAction +
    // RunCustomAction were lifted into the top-level KeyBindingRouter +
    // CustomActionRunner services. The two pass-through accessors below
    // remain on the god class as the seam the regression-guard tests
    // pin (Stage9Pr99Tests.GodClass_Has_PassThrough_Accessor) and as
    // the call site the registrar partial uses to dispatch resolved
    // chord events.
    internal void HandleKeyBindingActionForwarding(KeyBindingAction action)
        => _keyBindingRouter.Handle(action);

    internal void RunCustomActionForwarding(string verb)
        => _customActionRunner.Run(verb);
}
