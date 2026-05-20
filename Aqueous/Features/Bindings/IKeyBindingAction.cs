using Aqueous.Features.Compositor.River;

namespace Aqueous.Features.Bindings;

/// <summary>
/// Built-in <see cref="KeyBindingAction"/> dispatch service seam.
/// </summary>
internal interface IKeyBindingRouter
{
    /// <summary>
    /// Dispatch a built-in key-binding action. Pump-thread only.
    /// </summary>
    void Handle(KeyBindingAction action);
}

/// <summary>
/// Per-seat key-binding registrar (xkb chord declarations) + event-arrival entry point service
/// seam.
/// </summary>
internal interface IKeyBindingRegistrar
{
    /// <summary>
    /// Register every chord declared in the layout config for the given seat.
    /// </summary>
    void RegisterAllBindings(System.IntPtr seatProxy);

    /// <summary>
    /// True if the given native binding proxy has been registered.
    /// </summary>
    bool IsRegistered(System.IntPtr bindingProxy);
}
