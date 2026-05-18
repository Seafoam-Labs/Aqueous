namespace Aqueous.Features.Compositor.River.Dispatch;

/// <summary>
/// Routes a decoded <see cref="WlEvent"/> to the single
/// <see cref="IEventHandler"/> registered for its
/// <see cref="WlEvent.InterfaceName"/>.
///
/// Threading contract: <see cref="Dispatch"/> is called on the
/// <em>pump thread only</em>. Implementations are not required to be
/// thread-safe for concurrent dispatches.
/// </summary>
public interface IEventDispatcher
{
    /// <summary>
    /// Look up the handler for <paramref name="ev"/>'s interface and
    /// invoke <see cref="IEventHandler.Handle"/>. If no handler is
    /// registered for the interface, the event is logged at trace level
    /// and silently dropped — unknown interfaces are <b>not</b> an error,
    /// since the compositor may emit events for globals this client did
    /// not bind.
    /// </summary>
    void Dispatch(WlEvent ev);
}
