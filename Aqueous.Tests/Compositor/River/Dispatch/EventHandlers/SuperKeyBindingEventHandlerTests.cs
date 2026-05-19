using System;
using System.Linq;
using System.Reflection;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Dispatch.EventHandlers;

public unsafe class SuperKeyBindingEventHandlerTests
{
    private sealed class FakeBridge : ISuperKeyBindingHandlerCollaborators
    {
        public int Calls;
        public uint LastOpcode;
        public IntPtr LastArgsPtr;

        void ISuperKeyBindingHandlerCollaborators.HandleByPartial(uint opcode, WlArgument* args)
        {
            Calls++;
            LastOpcode = opcode;
            LastArgsPtr = (IntPtr)args;
        }
    }

    [Fact]
    public void InterfaceName_is_correct()
    {
        var h = new SuperKeyBindingEventHandler(new FakeBridge());
        Assert.Equal("river_super_key_binding_v1", h.InterfaceName);
    }

    [Fact]
    public void Ctor_rejects_null_river()
    {
        Assert.Throws<ArgumentNullException>(() => new SuperKeyBindingEventHandler(null!));
    }

    [Fact]
    public void Ctor_accepts_null_log()
    {
        var h = new SuperKeyBindingEventHandler(new FakeBridge(), null);
        Assert.NotNull(h);
    }

    [Fact]
    public void Handle_with_args_forwards_pointer_and_opcode_to_bridge()
    {
        var b = new FakeBridge();
        var h = new SuperKeyBindingEventHandler(b);
        var args = stackalloc WlArgument[1];
        h.Handle(new WlEvent(
            "river_super_key_binding_v1",
            target: new IntPtr(0x1234),
            opcode: RiverProtocolOpcodes.Binding.Pressed,
            argsPtr: (IntPtr)args,
            argCount: 0));
        Assert.Equal(1, b.Calls);
        Assert.Equal(RiverProtocolOpcodes.Binding.Pressed, b.LastOpcode);
        Assert.Equal((IntPtr)args, b.LastArgsPtr);
    }

    [Fact]
    public void Handle_with_zero_argsptr_forwards_null_pointer()
    {
        var b = new FakeBridge();
        var h = new SuperKeyBindingEventHandler(b);
        h.Handle(new WlEvent(
            "river_super_key_binding_v1",
            target: new IntPtr(0x42),
            opcode: RiverProtocolOpcodes.Binding.Released,
            argsPtr: IntPtr.Zero,
            argCount: 0));
        Assert.Equal(1, b.Calls);
        Assert.Equal(RiverProtocolOpcodes.Binding.Released, b.LastOpcode);
        Assert.Equal(IntPtr.Zero, b.LastArgsPtr);
    }

    [Fact]
    public void Handle_unknown_opcode_still_forwards()
    {
        var b = new FakeBridge();
        var h = new SuperKeyBindingEventHandler(b);
        h.Handle(new WlEvent(
            "river_super_key_binding_v1",
            target: new IntPtr(0x99),
            opcode: 99u,
            argsPtr: IntPtr.Zero,
            argCount: 0));
        Assert.Equal(1, b.Calls);
        Assert.Equal(99u, b.LastOpcode);
    }

    [Fact]
    public void Multiple_dispatches_increment_counter()
    {
        var b = new FakeBridge();
        var h = new SuperKeyBindingEventHandler(b);
        for (uint op = 0; op < 5; op++)
        {
            h.Handle(new WlEvent("river_super_key_binding_v1", IntPtr.Zero, op, IntPtr.Zero, 0));
        }
        Assert.Equal(5, b.Calls);
    }

    // ------- PR 8.6 decomposition regression guards -------

    [Fact]
    public void Bridge_interface_exists_with_correct_shape()
    {
        var t = typeof(ISuperKeyBindingHandlerCollaborators);
        Assert.True(t.IsInterface);
        var m = t.GetMethod("HandleByPartial",
            BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
        Assert.NotNull(m);
        var ps = m!.GetParameters();
        Assert.Equal(2, ps.Length);
        Assert.Equal(typeof(uint), ps[0].ParameterType);
        Assert.True(ps[1].ParameterType.IsPointer);
    }

    [Fact]
    public void God_class_implements_super_key_binding_bridge()
    {
        var t = typeof(RiverWindowManagerClient);
        Assert.Contains(typeof(ISuperKeyBindingHandlerCollaborators), t.GetInterfaces());
    }

    [Fact]
    public void Handler_is_sealed_and_implements_IEventHandler()
    {
        var t = typeof(SuperKeyBindingEventHandler);
        Assert.True(t.IsSealed);
        Assert.Contains(typeof(IEventHandler), t.GetInterfaces());
    }
}
