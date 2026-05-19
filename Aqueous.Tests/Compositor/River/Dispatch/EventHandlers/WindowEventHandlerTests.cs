using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
using Aqueous.Features.Compositor.River.Registry;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// PR 8.4 — unit tests for the managed <see cref="WindowEventHandler"/>.
/// The handler is currently a pass-through to
/// <see cref="IWindowHandlerCollaborators.HandleByPartial"/>, so the
/// tests assert routing semantics (correct opcode/target forwarded,
/// unknown-window early return, ctor guards, interface name) rather
/// than per-opcode behaviour, which is exercised end-to-end against
/// the real partial via the established ProxyDispatcher path.
/// </summary>
public sealed unsafe class WindowEventHandlerTests
{
    private sealed class FakeBridge : IWindowHandlerCollaborators
    {
        public int Calls;
        public IntPtr LastWindow;
        public uint LastOpcode;
        public bool LastArgsWasNull;

        void IWindowHandlerCollaborators.HandleByPartial(IntPtr window, uint opcode, WlArgument* args)
        {
            Calls++;
            LastWindow = window;
            LastOpcode = opcode;
            LastArgsWasNull = args == null;
        }
    }

    private static (WindowEventHandler handler, WindowRegistry windows, FakeBridge bridge) Build()
    {
        var windows = new WindowRegistry();
        var bridge = new FakeBridge();
        var handler = new WindowEventHandler(windows, bridge);
        return (handler, windows, bridge);
    }

    [Fact]
    public void InterfaceName_is_river_window_v1()
    {
        var (handler, _, _) = Build();
        Assert.Equal("river_window_v1", handler.InterfaceName);
    }

    [Fact]
    public void Ctor_null_windows_throws()
    {
        Assert.Throws<ArgumentNullException>(
            () => new WindowEventHandler(null!, new FakeBridge()));
    }

    [Fact]
    public void Ctor_null_river_throws_v2()
    {
        Assert.Throws<ArgumentNullException>(
            () => new WindowEventHandler(new WindowRegistry(), null!));
    }

    [Fact]
    public void Ctor_null_log_allowed()
    {
        // log is optional; constructor must not throw on a null sink.
        _ = new WindowEventHandler(new WindowRegistry(), new FakeBridge(), log: null);
    }

    [Fact]
    public void Handle_unknown_window_is_noop()
    {
        var (handler, _, bridge) = Build();
        var win = new IntPtr(0xabc);
        handler.Handle(new WlEvent("river_window_v1", win, RiverProtocolOpcodes.Window.Title, IntPtr.Zero, 0));
        Assert.Equal(0, bridge.Calls);
    }

    [Fact]
    public void Handle_known_window_forwards_to_bridge_with_correct_opcode()
    {
        var (handler, windows, bridge) = Build();
        var win = new IntPtr(0xdef);
        windows.Track(win);

        // Build a synthetic WlArgument array to ensure the args pointer
        // is forwarded as a real pointer (not nulled out).
        var args = stackalloc WlArgument[2];
        args[0].i = 42;
        args[1].i = 99;

        handler.Handle(new WlEvent(
            "river_window_v1",
            win,
            RiverProtocolOpcodes.Window.Dimensions,
            (IntPtr)args,
            2));

        Assert.Equal(1, bridge.Calls);
        Assert.Equal(win, bridge.LastWindow);
        Assert.Equal(RiverProtocolOpcodes.Window.Dimensions, bridge.LastOpcode);
        Assert.False(bridge.LastArgsWasNull);
    }

    [Fact]
    public void Handle_zero_argsPtr_forwards_null_pointer()
    {
        var (handler, windows, bridge) = Build();
        var win = new IntPtr(0xfee);
        windows.Track(win);

        // Closed has no args (ArgCount=0); the partial guards on the
        // closed opcode internally. The managed handler must forward
        // a real null pointer (not a wild pointer) so the partial's
        // arg-free branches are reached safely.
        handler.Handle(new WlEvent(
            "river_window_v1",
            win,
            RiverProtocolOpcodes.Window.Closed,
            IntPtr.Zero,
            0));

        Assert.Equal(1, bridge.Calls);
        Assert.True(bridge.LastArgsWasNull);
    }

    [Fact]
    public void Handle_forwards_unknown_opcode_to_bridge()
    {
        // The managed handler doesn't validate opcode ranges — the
        // partial's default switch arm logs unknown opcodes. The
        // forwarding behaviour must therefore be opcode-agnostic.
        var (handler, windows, bridge) = Build();
        var win = new IntPtr(0x777);
        windows.Track(win);

        handler.Handle(new WlEvent("river_window_v1", win, opcode: 9999, IntPtr.Zero, 0));

        Assert.Equal(1, bridge.Calls);
        Assert.Equal((uint)9999, bridge.LastOpcode);
    }

    /// <summary>
    /// Structural regression guards for PR 8.4 — verifies the bridge,
    /// handler interface, and god-class wiring exist with the right
    /// shape so a future refactor that accidentally undoes the
    /// extraction trips a fast unit-test failure.
    /// </summary>
    public sealed class Pr84DecompositionGuards
    {
        [Fact]
        public void IWindowHandlerCollaborators_exposes_HandleByPartial()
        {
            var type = typeof(IWindowHandlerCollaborators);
            Assert.True(type.IsInterface, "IWindowHandlerCollaborators must be an interface.");
            var m = type.GetMethod("HandleByPartial");
            Assert.NotNull(m);
            var parms = m!.GetParameters();
            Assert.Equal(3, parms.Length);
            Assert.Equal(typeof(IntPtr), parms[0].ParameterType);
            Assert.Equal(typeof(uint), parms[1].ParameterType);
            // Third param is WlArgument* (unsafe pointer); reflection
            // reports it as a pointer type — we just check it isn't
            // a managed reference type so the signature stays unsafe.
            Assert.True(parms[2].ParameterType.IsPointer);
        }

        [Fact]
        public void RiverWindowManagerClient_implements_IWindowHandlerCollaborators()
        {
            var rwmc = typeof(RiverWindowManagerClient);
            Assert.Contains(typeof(IWindowHandlerCollaborators), rwmc.GetInterfaces());
        }

        [Fact]
        public void WindowEventHandler_implements_IEventHandler_with_correct_InterfaceName()
        {
            var t = typeof(WindowEventHandler);
            Assert.True(t.IsSealed, "WindowEventHandler must be sealed.");
            Assert.Contains(typeof(IEventHandler), t.GetInterfaces());
            // Sanity: the interface-name string is the canonical
            // protocol name used by ProxyDispatcher's allowlist.
            var instance = new WindowEventHandler(
                new WindowRegistry(),
                new FakeBridge());
            Assert.Equal("river_window_v1", ((IEventHandler)instance).InterfaceName);
        }
    }
}
