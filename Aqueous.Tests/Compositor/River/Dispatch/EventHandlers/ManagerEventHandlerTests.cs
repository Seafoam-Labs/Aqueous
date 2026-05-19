using System;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// PR 8.5 — unit tests for the managed <see cref="ManagerEventHandler"/>.
/// The handler is currently a pass-through to
/// <see cref="IManagerHandlerCollaborators.HandleByPartial"/>, so the
/// tests assert routing semantics (correct opcode/args forwarded,
/// ctor guards, interface name) rather than per-opcode behaviour,
/// which is exercised end-to-end against the real partial via the
/// established ProxyDispatcher path.
///
/// Unlike windows/outputs/seats, the manager has no registry to
/// validate the target against — ProxyDispatcher gates the manager
/// branch on a single-proxy identity check (`target == self._manager`),
/// so there is no unknown-target early return to test.
/// </summary>
public sealed unsafe class ManagerEventHandlerTests
{
    private sealed class FakeBridge : IManagerHandlerCollaborators
    {
        public int Calls;
        public uint LastOpcode;
        public bool LastArgsWasNull;

        void IManagerHandlerCollaborators.HandleByPartial(uint opcode, WlArgument* args)
        {
            Calls++;
            LastOpcode = opcode;
            LastArgsWasNull = args == null;
        }
    }

    private static (ManagerEventHandler handler, FakeBridge bridge) Build()
    {
        var bridge = new FakeBridge();
        var handler = new ManagerEventHandler(bridge);
        return (handler, bridge);
    }

    [Fact]
    public void InterfaceName_is_river_window_manager_v1()
    {
        var (handler, _) = Build();
        Assert.Equal("river_window_manager_v1", handler.InterfaceName);
    }

    [Fact]
    public void Ctor_null_river_throws()
    {
        Assert.Throws<ArgumentNullException>(
            () => new ManagerEventHandler(null!));
    }

    [Fact]
    public void Ctor_null_log_allowed()
    {
        // log is optional; constructor must not throw on a null sink.
        _ = new ManagerEventHandler(new FakeBridge(), log: null);
    }

    [Fact]
    public void Handle_forwards_with_correct_opcode_and_args_pointer()
    {
        var (handler, bridge) = Build();

        // Build a synthetic WlArgument array to ensure the args pointer
        // is forwarded as a real pointer (not nulled out).
        var args = stackalloc WlArgument[3];
        args[0].i = 1;
        args[1].i = 2;
        args[2].i = 3;

        handler.Handle(new WlEvent(
            "river_window_manager_v1",
            target: new IntPtr(0x1234),
            opcode: RiverProtocolOpcodes.Manager.ManageStart,
            argsPtr: (IntPtr)args,
            argCount: 3));

        Assert.Equal(1, bridge.Calls);
        Assert.Equal(RiverProtocolOpcodes.Manager.ManageStart, bridge.LastOpcode);
        Assert.False(bridge.LastArgsWasNull);
    }

    [Fact]
    public void Handle_zero_argsPtr_forwards_null_pointer()
    {
        var (handler, bridge) = Build();

        // unavailable/finished/manage_end have no args; the managed
        // handler must forward a real null pointer (not a wild
        // pointer) so the partial's arg-free branches are reached
        // safely.
        handler.Handle(new WlEvent(
            "river_window_manager_v1",
            target: new IntPtr(0x1234),
            opcode: RiverProtocolOpcodes.Manager.Unavailable,
            argsPtr: IntPtr.Zero,
            argCount: 0));

        Assert.Equal(1, bridge.Calls);
        Assert.Equal(RiverProtocolOpcodes.Manager.Unavailable, bridge.LastOpcode);
        Assert.True(bridge.LastArgsWasNull);
    }

    [Fact]
    public void Handle_forwards_unknown_opcode_to_bridge()
    {
        // The managed handler doesn't validate opcode ranges — the
        // partial's default switch arm logs unknown opcodes. The
        // forwarding behaviour must therefore be opcode-agnostic.
        var (handler, bridge) = Build();

        handler.Handle(new WlEvent(
            "river_window_manager_v1",
            target: new IntPtr(0x1234),
            opcode: 9999,
            argsPtr: IntPtr.Zero,
            argCount: 0));

        Assert.Equal(1, bridge.Calls);
        Assert.Equal((uint)9999, bridge.LastOpcode);
    }

    [Fact]
    public void Handle_multiple_dispatches_increments_call_count()
    {
        var (handler, bridge) = Build();
        handler.Handle(new WlEvent("river_window_manager_v1", new IntPtr(1), 0, IntPtr.Zero, 0));
        handler.Handle(new WlEvent("river_window_manager_v1", new IntPtr(1), 1, IntPtr.Zero, 0));
        handler.Handle(new WlEvent("river_window_manager_v1", new IntPtr(1), 2, IntPtr.Zero, 0));
        Assert.Equal(3, bridge.Calls);
        Assert.Equal((uint)2, bridge.LastOpcode);
    }

    /// <summary>
    /// Structural regression guards for PR 8.5 — verifies the bridge,
    /// handler interface, and god-class wiring exist with the right
    /// shape so a future refactor that accidentally undoes the
    /// extraction trips a fast unit-test failure.
    /// </summary>
    public sealed class Pr85DecompositionGuards
    {
        [Fact]
        public void IManagerHandlerCollaborators_exposes_HandleByPartial()
        {
            var type = typeof(IManagerHandlerCollaborators);
            Assert.True(type.IsInterface, "IManagerHandlerCollaborators must be an interface.");
            var m = type.GetMethod("HandleByPartial");
            Assert.NotNull(m);
            var parms = m!.GetParameters();
            // (uint opcode, WlArgument* args) — note: no IntPtr target,
            // unlike the window/output/seat bridges. The manager is a
            // singleton proxy resolved at bind time so the target is
            // implicit.
            Assert.Equal(2, parms.Length);
            Assert.Equal(typeof(uint), parms[0].ParameterType);
            Assert.True(parms[1].ParameterType.IsPointer);
        }

        [Fact]
        public void RiverWindowManagerClient_implements_IManagerHandlerCollaborators()
        {
            var rwmc = typeof(RiverWindowManagerClient);
            Assert.Contains(typeof(IManagerHandlerCollaborators), rwmc.GetInterfaces());
        }

        [Fact]
        public void ManagerEventHandler_implements_IEventHandler_with_correct_InterfaceName()
        {
            var t = typeof(ManagerEventHandler);
            Assert.True(t.IsSealed, "ManagerEventHandler must be sealed.");
            Assert.Contains(typeof(IEventHandler), t.GetInterfaces());
            var instance = new ManagerEventHandler(new FakeBridge());
            Assert.Equal("river_window_manager_v1", ((IEventHandler)instance).InterfaceName);
        }
    }
}
