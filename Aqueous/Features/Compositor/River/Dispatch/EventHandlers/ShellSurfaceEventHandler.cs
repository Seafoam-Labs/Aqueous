using System;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// <see cref="IEventHandler"/> for <c>river_shell_surface_v1</c>. The only event of interest is
/// <c>destroyed</c> (opcode 0, since protocol v5): the compositor emits it immediately before a
/// shell-surface object becomes invalid server-side (e.g. a fast-closing layer-shell client such as
/// sherlock). Routing it through <see cref="SeatInteractionService.HandleShellSurfaceDestroyed"/>
/// deterministically drops any pending focus that still targets the proxy and destroys it, so the
/// manage cycle can never marshal <c>focus_shell_surface</c> on a freed proxy (the
/// "segfault at 2c … libwayland-client" crash).
/// <para>
/// Pump-thread only: invoked by the native callback via <see cref="IEventDispatcher.Dispatch"/>.
/// </para>
/// </summary>
internal sealed class ShellSurfaceEventHandler : IEventHandler
{
    private readonly SeatInteractionService _interaction;

    public ShellSurfaceEventHandler(SeatInteractionService interaction)
    {
        _interaction = interaction ?? throw new ArgumentNullException(nameof(interaction));
    }

    public string InterfaceName => "river_shell_surface_v1";

    public void Handle(WlEvent ev)
    {
        if (ev.Opcode != RiverProtocolOpcodes.ShellSurface.Destroyed)
        {
            return;
        }

        _interaction.HandleShellSurfaceDestroyed(ev.Target);
    }
}
