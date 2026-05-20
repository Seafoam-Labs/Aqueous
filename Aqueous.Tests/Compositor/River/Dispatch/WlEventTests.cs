using System;
using Aqueous.Features.Compositor.River.Dispatch;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Dispatch;

/// <summary>
/// Unit tests for the extension of <see cref="WlEvent"/>: the new <c>(string, IntPtr, uint,
/// IntPtr, int)</c> ctor and the Target / ArgsPtr / ArgCount fields. The ctors are exercised
/// transitively by <see cref="EventDispatcherTests"/>.
/// </summary>
public sealed class WlEventTests
{
    [Fact]
    public void Stage8_ctor_populates_every_field()
    {
        var target = new IntPtr(0x1234);
        var args = new IntPtr(0x5678);
        var ev = new WlEvent("wl_seat", target, opcode: 3, argsPtr: args, argCount: 2);

        Assert.Equal("wl_seat", ev.InterfaceName);
        Assert.Equal(target, ev.Target);
        Assert.Equal(3u, ev.Opcode);
        Assert.Equal(args, ev.ArgsPtr);
        Assert.Equal(2, ev.ArgCount);
        Assert.True(ev.Args.IsEmpty);
    }

    [Fact]
    public void Stage4_ctor_leaves_Stage8_fields_zeroed()
    {
        var ev = new WlEvent("wl_output", opcode: 7);
        Assert.Equal(IntPtr.Zero, ev.Target);
        Assert.Equal(IntPtr.Zero, ev.ArgsPtr);
        Assert.Equal(0, ev.ArgCount);
        Assert.True(ev.Args.IsEmpty);
    }

    [Fact]
    public void Stage8_ctor_rejects_null_interface_name()
    {
        Assert.Throws<ArgumentNullException>(() =>
            new WlEvent(null!, IntPtr.Zero, 0, IntPtr.Zero, 0));
    }

    [Fact]
    public void Stage8_ctor_rejects_negative_arg_count()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            new WlEvent("wl_seat", IntPtr.Zero, 0, IntPtr.Zero, -1));
    }

    [Fact]
    public void Stage8_ctor_allows_zero_pointers_and_zero_arg_count()
    {
        // Synthetic event constructed in a test without a native payload.
        var ev = new WlEvent("zriver_window_v3", IntPtr.Zero, 0, IntPtr.Zero, 0);
        Assert.Equal(IntPtr.Zero, ev.Target);
        Assert.Equal(IntPtr.Zero, ev.ArgsPtr);
        Assert.Equal(0, ev.ArgCount);
    }
}
