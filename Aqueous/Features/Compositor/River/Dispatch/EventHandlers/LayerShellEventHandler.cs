using System;
using Aqueous.Features.Compositor.River.Dispatch;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// PR 8.1 — first <see cref="IEventHandler"/> extracted out of the
/// <c>RiverWindowManagerClient</c> god class.
///
/// Handles the single <c>river_layer_shell_v1::layer_surface</c> event
/// (opcode 0): on each newly-mapped layer surface, ask the compositor
/// for its <c>river_node_v1</c> child and place it above existing
/// nodes.
///
/// No managed state, no service dependencies — the body is a pair of
/// <c>wl_proxy_marshal_flags</c> P/Invokes plus a log line. The
/// optional <see cref="Action{String}"/> log sink keeps the handler
/// trivially unit-testable without pulling in <c>Microsoft.Extensions.Logging</c>.
///
/// PR 9.12 §2.13 Step 6: confirmed zero god-class coupling — the ctor
/// takes only an optional log sink, and the body has no
/// <c>RiverWindowManagerClient</c> reference. No cutover required for
/// this handler; the Step 6 check is a no-op aside from this note.
///
/// Pump-thread only: invoked by the native callback in
/// <c>ProxyDispatcher</c> via <see cref="IEventDispatcher.Dispatch"/>.
/// </summary>
internal sealed unsafe class LayerShellEventHandler : IEventHandler
{
    private readonly Action<string>? _log;

    public LayerShellEventHandler(Action<string>? log = null)
    {
        _log = log;
    }

    public string InterfaceName => "river_layer_shell_v1";

    public void Handle(WlEvent ev)
    {
        if (ev.Opcode != RiverProtocolOpcodes.LayerShell.LayerSurface)
        {
            return;
        }

        if (ev.ArgsPtr == IntPtr.Zero || ev.ArgCount < 1)
        {
            return;
        }

        var args = (WlArgument*)ev.ArgsPtr;
        IntPtr layerSurface = args[0].o;
        if (layerSurface == IntPtr.Zero)
        {
            return;
        }

        IntPtr node = WaylandInterop.wl_proxy_marshal_flags(
            layerSurface, 0, (IntPtr)WlInterfaces.RiverNode, 1, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        if (node == IntPtr.Zero)
        {
            return;
        }

        WaylandInterop.wl_proxy_marshal_flags(node, 2, IntPtr.Zero, 1, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

        _log?.Invoke("mapped layer_surface to top");
    }
}
