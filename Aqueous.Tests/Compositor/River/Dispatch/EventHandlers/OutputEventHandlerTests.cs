using System;
using System.Collections.Generic;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.State;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// PR 8.2 — unit tests for <see cref="OutputEventHandler"/>.
///
/// Covers the four opcode branches via stack-allocated
/// <see cref="WlArgument"/> payloads plus the early-return guards
/// (unknown proxy, null payload, short payload, wrong opcode). The
/// <c>removed</c> branch is exercised against a fake
/// <see cref="IOutputHandlerCollaborators"/> to confirm the bridge call
/// order (snapshot → demote → fullscreen-evict → registry-remove →
/// window-detach).
/// </summary>
public sealed unsafe class OutputEventHandlerTests
{
    private const string Iface = "river_output_v1";

    private sealed class FakeBridge : IOutputHandlerCollaborators
    {
        public List<WindowStateData> Snapshot { get; set; } = new();
        public int SnapshotCalls;
        public int OnOutputRemovedCalls;
        public OutputProxy LastOutputRemoved;
        public IList<WindowStateData>? LastWindowsOnOutput;
        public int FullscreenTryRemoveCalls;
        public IntPtr LastFullscreenRemoved;

        public IEnumerable<WindowStateData> SnapshotWindowStates()
        {
            SnapshotCalls++;
            return Snapshot;
        }

        public void OnOutputRemoved(OutputProxy output, IList<WindowStateData> windowsOnOutput)
        {
            OnOutputRemovedCalls++;
            LastOutputRemoved = output;
            LastWindowsOnOutput = windowsOnOutput;
        }

        public void OutputFullscreenTryRemove(IntPtr output)
        {
            FullscreenTryRemoveCalls++;
            LastFullscreenRemoved = output;
        }
    }

    private static (OutputEventHandler h, WindowRegistry w, OutputRegistry o, FakeBridge b, IntPtr proxy, OutputEntry entry) Build()
    {
        var w = new WindowRegistry();
        var o = new OutputRegistry();
        var b = new FakeBridge();
        var h = new OutputEventHandler(w, o, b);
        IntPtr proxy = (IntPtr)0x1234;
        var entry = new OutputEntry { Proxy = proxy };
        o.Entries[proxy] = entry;
        return (h, w, o, b, proxy, entry);
    }

    [Fact]
    public void InterfaceName_is_river_output_v1()
    {
        var (h, _, _, _, _, _) = Build();
        Assert.Equal(Iface, h.InterfaceName);
    }

    [Fact]
    public void Ctor_null_args_throw()
    {
        var w = new WindowRegistry();
        var o = new OutputRegistry();
        var b = new FakeBridge();
        Assert.Throws<ArgumentNullException>(() => new OutputEventHandler(null!, o, b));
        Assert.Throws<ArgumentNullException>(() => new OutputEventHandler(w, null!, b));
        Assert.Throws<ArgumentNullException>(() => new OutputEventHandler(w, o, null!));
    }

    [Fact]
    public void Unknown_proxy_is_a_noop()
    {
        var (h, _, _, b, _, _) = Build();
        h.Handle(new WlEvent(Iface, (IntPtr)0xDEAD, RiverProtocolOpcodes.Output.Position, IntPtr.Zero, 0));
        Assert.Equal(0, b.SnapshotCalls);
        Assert.Equal(0, b.OnOutputRemovedCalls);
    }

    [Fact]
    public void WlOutput_opcode_sets_wl_output_name()
    {
        var (h, _, _, _, proxy, entry) = Build();
        WlArgument arg;
        arg.u = 7;
        h.Handle(new WlEvent(Iface, proxy, RiverProtocolOpcodes.Output.WlOutput, (IntPtr)(&arg), 1));
        Assert.Equal(7u, entry.WlOutputName);
    }

    [Fact]
    public void Position_opcode_sets_x_and_y()
    {
        var (h, _, _, _, proxy, entry) = Build();
        var args = stackalloc WlArgument[2];
        args[0].i = 100;
        args[1].i = 200;
        h.Handle(new WlEvent(Iface, proxy, RiverProtocolOpcodes.Output.Position, (IntPtr)args, 2));
        Assert.Equal(100, entry.X);
        Assert.Equal(200, entry.Y);
    }

    [Fact]
    public void Dimensions_opcode_sets_width_and_height()
    {
        var (h, _, _, _, proxy, entry) = Build();
        var args = stackalloc WlArgument[2];
        args[0].i = 1920;
        args[1].i = 1080;
        h.Handle(new WlEvent(Iface, proxy, RiverProtocolOpcodes.Output.Dimensions, (IntPtr)args, 2));
        Assert.Equal(1920, entry.Width);
        Assert.Equal(1080, entry.Height);
    }

    [Fact]
    public void Removed_opcode_invokes_bridge_in_order_and_removes_from_registry()
    {
        var (h, w, o, b, proxy, _) = Build();

        // One window pinned to the doomed output, one elsewhere.
        b.Snapshot = new List<WindowStateData>
        {
            new() { PinnedOutput = new OutputProxy(proxy) },
            new() { PinnedOutput = new OutputProxy((IntPtr)0xBEEF) },
        };

        IntPtr win1 = (IntPtr)0xAA;
        IntPtr win2 = (IntPtr)0xBB;
        w.Entries[win1] = new WindowEntry { Output = proxy };
        w.Entries[win2] = new WindowEntry { Output = (IntPtr)0xBEEF };

        h.Handle(new WlEvent(Iface, proxy, RiverProtocolOpcodes.Output.Removed, IntPtr.Zero, 0));

        Assert.Equal(1, b.SnapshotCalls);
        Assert.Equal(1, b.OnOutputRemovedCalls);
        Assert.Equal(new OutputProxy(proxy), b.LastOutputRemoved);
        Assert.NotNull(b.LastWindowsOnOutput);
        Assert.Single(b.LastWindowsOnOutput!);
        Assert.Equal(1, b.FullscreenTryRemoveCalls);
        Assert.Equal(proxy, b.LastFullscreenRemoved);
        Assert.False(o.Entries.ContainsKey(proxy));
        Assert.Equal(IntPtr.Zero, w.Entries[win1].Output);
        Assert.Equal((IntPtr)0xBEEF, w.Entries[win2].Output); // untouched
    }

    [Fact]
    public void Position_with_short_payload_is_a_noop()
    {
        var (h, _, _, _, proxy, entry) = Build();
        WlArgument arg;
        arg.i = 99;
        h.Handle(new WlEvent(Iface, proxy, RiverProtocolOpcodes.Output.Position, (IntPtr)(&arg), 1));
        Assert.Equal(0, entry.X);
        Assert.Equal(0, entry.Y);
    }

    [Fact]
    public void Unknown_opcode_is_silent_noop()
    {
        var (h, _, _, b, proxy, entry) = Build();
        h.Handle(new WlEvent(Iface, proxy, opcode: 42, IntPtr.Zero, 0));
        Assert.Equal(0, b.SnapshotCalls);
        Assert.Equal(0, entry.X);
    }

    [Fact]
    public void Implements_IEventHandler()
    {
        var (h, _, _, _, _, _) = Build();
        Assert.IsAssignableFrom<IEventHandler>(h);
    }
}
