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

    /// <summary>
    /// Dispatch a built in key-binding action when the key is held down.
    /// </summary>
    /// <param name="action"></param>
    /// <param name="pressed"></param>
    void HandleHold(KeyBindingAction action, bool pressed);

    /// <summary>
    /// Records the bound <c>river_seat_v1</c> proxy for seat-scoped requests (e.g. pointer-constraint
    /// suppression). Pass <see cref="System.IntPtr.Zero"/> to clear.
    /// </summary>
    void SetSeat(System.IntPtr seat);
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
