using System;
using System.Linq;
using System.Reflection;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Dispatch.EventHandlers;

public sealed unsafe class DragPointerBindingEventHandlerTests
{
    private sealed class FakeBridge : IDragPointerBindingHandlerCollaborators
    {
        public int Calls;
        public IntPtr LastTarget;
        public uint LastOpcode;
        public IntPtr LastArgsPtr;

        public void HandleByPartial(IntPtr target, uint opcode, WlArgument* args)
        {
            Calls++;
            LastTarget = target;
            LastOpcode = opcode;
            LastArgsPtr = (IntPtr)args;
        }
    }

    [Fact]
    public void InterfaceName_is_river_pointer_binding_v1()
    {
        var h = new DragPointerBindingEventHandler(new FakeBridge());
        Assert.Equal("river_pointer_binding_v1", h.InterfaceName);
    }

    [Fact]
    public void Ctor_throws_on_null_bridge()
    {
        Assert.Throws<ArgumentNullException>(() => new DragPointerBindingEventHandler(null!));
    }

    [Fact]
    public void Ctor_accepts_null_log()
    {
        var h = new DragPointerBindingEventHandler(new FakeBridge(), null);
        Assert.NotNull(h);
    }

    [Fact]
    public void Handle_forwards_to_bridge_with_target_opcode_and_args()
    {
        var b = new FakeBridge();
        var h = new DragPointerBindingEventHandler(b);
        var args = stackalloc WlArgument[1];
        args[0].i = 42;
        var target = new IntPtr(0xDEADBEEF);
        h.Handle(new WlEvent("river_pointer_binding_v1", target, opcode: 3, argsPtr: (IntPtr)args, argCount: 1));
        Assert.Equal(1, b.Calls);
        Assert.Equal(target, b.LastTarget);
        Assert.Equal(3u, b.LastOpcode);
        Assert.Equal((IntPtr)args, b.LastArgsPtr);
    }

    [Fact]
    public void Handle_zero_ArgsPtr_forwards_null_pointer()
    {
        var b = new FakeBridge();
        var h = new DragPointerBindingEventHandler(b);
        h.Handle(new WlEvent("river_pointer_binding_v1", new IntPtr(1), opcode: 0, argsPtr: IntPtr.Zero, argCount: 0));
        Assert.Equal(1, b.Calls);
        Assert.Equal(IntPtr.Zero, b.LastArgsPtr);
    }

    [Fact]
    public void Handle_unknown_opcode_still_forwards()
    {
        var b = new FakeBridge();
        var h = new DragPointerBindingEventHandler(b);
        h.Handle(new WlEvent("river_pointer_binding_v1", new IntPtr(7), opcode: 9999, argsPtr: IntPtr.Zero, argCount: 0));
        Assert.Equal(1, b.Calls);
        Assert.Equal(9999u, b.LastOpcode);
    }

    [Fact]
    public void Handle_multiple_dispatches_increments_counter()
    {
        var b = new FakeBridge();
        var h = new DragPointerBindingEventHandler(b);
        for (int i = 0; i < 5; i++)
        {
            h.Handle(new WlEvent("river_pointer_binding_v1", new IntPtr(i + 1), opcode: (uint)i, argsPtr: IntPtr.Zero, argCount: 0));
        }
        Assert.Equal(5, b.Calls);
    }

    // ---- Stage 8 PR 8.7 decomposition regression guards ----

    [Fact]
    public void Bridge_interface_has_only_HandleByPartial()
    {
        var members = typeof(IDragPointerBindingHandlerCollaborators).GetMembers(
            BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly);
        Assert.Single(members);
        Assert.Equal("HandleByPartial", members[0].Name);
    }

    [Fact]
    public void RiverWindowManagerClient_implements_IDragPointerBindingHandlerCollaborators()
    {
        Assert.Contains(
            typeof(IDragPointerBindingHandlerCollaborators),
            typeof(RiverWindowManagerClient).GetInterfaces());
    }

    [Fact]
    public void DragPointerBindingEventHandler_is_sealed_and_implements_IEventHandler()
    {
        var t = typeof(DragPointerBindingEventHandler);
        Assert.True(t.IsSealed);
        Assert.Contains(typeof(IEventHandler), t.GetInterfaces());
        var h = new DragPointerBindingEventHandler(new FakeBridge());
        Assert.Equal("river_pointer_binding_v1", h.InterfaceName);
    }
}
