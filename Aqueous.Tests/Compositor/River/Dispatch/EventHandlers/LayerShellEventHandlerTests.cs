using System;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// PR 8.1 — unit tests for <see cref="LayerShellEventHandler"/>.
///
/// The happy path of <see cref="LayerShellEventHandler.Handle"/> issues
/// two <c>wl_proxy_marshal_flags</c> P/Invokes against a real
/// <c>wl_proxy*</c>. Synthesising one of those in a unit test is not
/// feasible, so the suite focuses on the early-return guards (wrong
/// opcode, zero-pointer payload, zero <c>layer_surface</c> arg) plus
/// the <see cref="IEventHandler"/> contract (interface name, ctor
/// tolerance for a null log sink).
/// </summary>
public sealed unsafe class LayerShellEventHandlerTests
{
    [Fact]
    public void InterfaceName_is_river_layer_shell_v1()
    {
        var h = new LayerShellEventHandler();
        Assert.Equal("river_layer_shell_v1", h.InterfaceName);
    }

    [Fact]
    public void Ctor_accepts_null_log()
    {
        var h = new LayerShellEventHandler(log: null);
        // Should not throw on Handle either (wrong-opcode short-circuits before log site).
        h.Handle(new WlEvent("river_layer_shell_v1", IntPtr.Zero, opcode: 42, argsPtr: IntPtr.Zero, argCount: 0));
    }

    [Fact]
    public void Wrong_opcode_is_a_noop()
    {
        var calls = 0;
        var h = new LayerShellEventHandler(_ => calls++);

        // Opcode 1 is not LayerSurface (0); handler must short-circuit
        // before touching ArgsPtr.
        h.Handle(new WlEvent("river_layer_shell_v1", IntPtr.Zero, opcode: 1, argsPtr: IntPtr.Zero, argCount: 0));

        Assert.Equal(0, calls);
    }

    [Fact]
    public void Zero_args_ptr_is_a_noop()
    {
        var calls = 0;
        var h = new LayerShellEventHandler(_ => calls++);

        // Correct opcode (0 = LayerSurface) but a null argument array —
        // handler must defensively short-circuit instead of dereferencing.
        h.Handle(new WlEvent("river_layer_shell_v1", IntPtr.Zero,
            opcode: RiverProtocolOpcodes.LayerShell.LayerSurface,
            argsPtr: IntPtr.Zero,
            argCount: 0));

        Assert.Equal(0, calls);
    }

    [Fact]
    public void Zero_layer_surface_arg_is_a_noop()
    {
        var calls = 0;
        var h = new LayerShellEventHandler(_ => calls++);

        // Construct a real argument slot in stack memory with a zero
        // 'o' field — handler must short-circuit before issuing the
        // first wl_proxy_marshal_flags call.
        WlArgument arg = default; // .o == IntPtr.Zero
        var argPtr = new IntPtr(&arg);

        h.Handle(new WlEvent("river_layer_shell_v1", IntPtr.Zero,
            opcode: RiverProtocolOpcodes.LayerShell.LayerSurface,
            argsPtr: argPtr,
            argCount: 1));

        Assert.Equal(0, calls);
    }

    [Fact]
    public void Implements_IEventHandler()
    {
        IEventHandler h = new LayerShellEventHandler();
        Assert.NotNull(h);
        Assert.False(string.IsNullOrEmpty(h.InterfaceName));
    }
}
