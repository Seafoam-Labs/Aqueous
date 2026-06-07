using System;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Compositor.River.Registry;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// <see cref="IEventHandler"/> for <c>river_layer_shell_output_v1</c> (the per-output sub-object
/// created via <c>river_layer_shell_v1.get_output</c>). It receives the single
/// <c>non_exclusive_area</c> event (opcode 0, signature <c>iiii</c> = x, y, width, height in global
/// coordinates) and records the usable area for the parent output in
/// <see cref="ILayerShellUsableAreaStore"/> so the layout pipeline can avoid overlapping panels/bars.
/// The parent <c>river_output_v1</c> is resolved from the firing sub-object
/// proxy via the association map populated at creation
/// (<see cref="WaylandBindSiteState.OutputByLayerShellOutput"/>).
/// <para>
/// Pump-thread only: invoked by the native callback via <see cref="IEventDispatcher.Dispatch"/>.
/// </para>
/// </summary>
internal sealed unsafe class LayerShellOutputEventHandler : IEventHandler
{
    private readonly ILayerShellUsableAreaStore _usableAreas;
    private readonly WaylandBindSiteState _bindSiteState;
    private readonly Action<string>? _log;

    public LayerShellOutputEventHandler(
        ILayerShellUsableAreaStore usableAreas,
        WaylandBindSiteState bindSiteState,
        Action<string>? log = null)
    {
        _usableAreas = usableAreas ?? throw new ArgumentNullException(nameof(usableAreas));
        _bindSiteState = bindSiteState ?? throw new ArgumentNullException(nameof(bindSiteState));
        _log = log;
    }

    public string InterfaceName => "river_layer_shell_output_v1";

    public void Handle(WlEvent ev)
    {
        if (ev.Opcode != RiverProtocolOpcodes.LayerShellOutput.NonExclusiveArea)
        {
            return;
        }

        if (ev.ArgsPtr == IntPtr.Zero || ev.ArgCount < 4)
        {
            return;
        }

        if (!_bindSiteState.OutputByLayerShellOutput.TryGetValue(ev.Target, out var output) || output == IntPtr.Zero)
        {
            return;
        }

        var args = (WlArgument*)ev.ArgsPtr;
        int x = args[0].i;
        int y = args[1].i;
        int width = args[2].i;
        int height = args[3].i;

        _usableAreas.Set(output, x, y, width, height);
        _log?.Invoke(
            $"layer_shell_output non_exclusive_area on output 0x{output:x}: {x},{y} {width}x{height}");
    }
}
