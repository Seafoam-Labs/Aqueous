using System;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
using Aqueous.Features.Compositor.River.Registry;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// Behavioural coverage for <see cref="LayerShellOutputEventHandler"/>: the
/// <c>non_exclusive_area</c> event (opcode 0, signature <c>iiii</c>) must record the usable area
/// for the parent <c>river_output_v1</c> resolved from the firing sub-object proxy.
/// </summary>
public sealed unsafe class LayerShellOutputEventHandlerTests
{
    private static readonly IntPtr LsOutput = new(0x3000);
    private static readonly IntPtr Output = new(0x4000);

    private static (LayerShellOutputEventHandler handler, LayerShellUsableAreaStore store) Build()
    {
        var store = new LayerShellUsableAreaStore();
        var bind = new WaylandBindSiteState();
        bind.OutputByLayerShellOutput[LsOutput] = Output;
        bind.LayerShellOutputByOutput[Output] = LsOutput;
        var handler = new LayerShellOutputEventHandler(store, bind);
        return (handler, store);
    }

    [Fact]
    public void InterfaceName_is_layer_shell_output()
    {
        var (handler, _) = Build();
        Assert.Equal("river_layer_shell_output_v1", handler.InterfaceName);
        Assert.Contains(typeof(IEventHandler), typeof(LayerShellOutputEventHandler).GetInterfaces());
    }

    [Fact]
    public void NonExclusiveArea_updates_usable_area_for_resolved_output()
    {
        var (handler, store) = Build();

        var args = stackalloc WlArgument[4];
        args[0].i = 10;
        args[1].i = 20;
        args[2].i = 1900;
        args[3].i = 1040;

        handler.Handle(new WlEvent("river_layer_shell_output_v1", LsOutput,
            RiverProtocolOpcodes.LayerShellOutput.NonExclusiveArea, (IntPtr)args, 4));

        Assert.True(store.TryGet(Output, out var area));
        Assert.Equal((10, 20, 1900, 1040), area);
    }

    [Fact]
    public void Unknown_subobject_proxy_is_a_no_op()
    {
        var (handler, store) = Build();

        var args = stackalloc WlArgument[4];
        args[0].i = 1;
        args[1].i = 2;
        args[2].i = 3;
        args[3].i = 4;

        handler.Handle(new WlEvent("river_layer_shell_output_v1", new IntPtr(0xBEEF),
            RiverProtocolOpcodes.LayerShellOutput.NonExclusiveArea, (IntPtr)args, 4));

        Assert.False(store.TryGet(Output, out _));
    }

    [Fact]
    public void NonExclusiveArea_opcode_is_zero()
    {
        Assert.Equal(0u, RiverProtocolOpcodes.LayerShellOutput.NonExclusiveArea);
    }
}
