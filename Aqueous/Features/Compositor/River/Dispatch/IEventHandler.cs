namespace Aqueous.Features.Compositor.River.Dispatch;

/// <summary>
/// A per-Wayland-interface event handler. One implementation per protocol interface (e.g. one for
/// <c>wl_seat</c>, one for <c>zriver_window_manager_v3</c>). The <see cref="IEventDispatcher"/>
/// routes every <see cref="WlEvent"/> to the single handler whose <see cref="InterfaceName"/>
/// equals the event's interface, comparing with <see cref="System.StringComparer.Ordinal"/>.
/// Threading contract: implementations are invoked on the <em>pump thread only</em>. They must not
/// be called concurrently and they must not block; long-running work should be enqueued onto a
/// service the handler depends on rather than performed in <see cref="Handle"/>.
/// </summary>
public interface IEventHandler
{
    /// <summary>
    /// Wayland interface name this handler is responsible for. Must be stable for the lifetime of the
    /// handler instance — the dispatch table is built once at <see cref="IEventDispatcher"/>
    /// construction.
    /// </summary>
    string InterfaceName { get; }

    /// <summary>
    /// Handle a decoded Wayland event whose <see cref="WlEvent.InterfaceName"/> equals <see
    /// cref="InterfaceName"/>. Called on the pump thread only.
    /// </summary>
    void Handle(WlEvent ev);
}
