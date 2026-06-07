using System;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Focus;
using Xunit;

namespace Aqueous.Tests.Compositor.River;

/// <summary>
/// Coverage for Phase E of the <c>river-layer-shell-v1</c> migration: <see
/// cref="LayerShellTeardownService"/> must drop the per-seat/per-output association maps and clear
/// the dependent focus/usable-area state when a parent is removed.
/// <para>
/// The sub-object proxies are deliberately left untracked in <see cref="WaylandBindSiteState"/>'s
/// proxy-interface map, so the destructor short-circuits before any native
/// <c>wl_proxy_marshal_flags</c> call (which would dereference the fake <see cref="IntPtr"/>).
/// </para>
/// </summary>
public sealed class LayerShellTeardownServiceTests
{
    private static readonly IntPtr Seat = new(0x2000);
    private static readonly IntPtr LsSeat = new(0x1000);
    private static readonly IntPtr Output = new(0x4000);
    private static readonly IntPtr LsOutput = new(0x3000);

    private static (LayerShellTeardownService svc, WaylandBindSiteState bind, LayerShellFocusState focus, LayerShellUsableAreaStore usable) Build()
    {
        var bind = new WaylandBindSiteState();
        var focus = new LayerShellFocusState();
        var usable = new LayerShellUsableAreaStore();
        var svc = new LayerShellTeardownService(bind, focus, usable);
        return (svc, bind, focus, usable);
    }

    [Fact]
    public void TeardownSeat_clears_focus_state_and_association_maps()
    {
        var (svc, bind, focus, _) = Build();
        bind.LayerShellSeatBySeat[Seat] = LsSeat;
        bind.SeatByLayerShellSeat[LsSeat] = Seat;
        focus.SetExclusive(Seat);

        svc.TeardownSeat(Seat);

        Assert.False(focus.IsFocusLocked(Seat));
        Assert.Equal(LayerFocusMode.None, focus.ModeFor(Seat));
        Assert.False(bind.LayerShellSeatBySeat.ContainsKey(Seat));
        Assert.False(bind.SeatByLayerShellSeat.ContainsKey(LsSeat));
    }

    [Fact]
    public void TeardownSeat_without_subobject_still_clears_focus()
    {
        var (svc, bind, focus, _) = Build();
        focus.SetExclusive(Seat);

        svc.TeardownSeat(Seat);

        Assert.False(focus.IsFocusLocked(Seat));
        Assert.Empty(bind.LayerShellSeatBySeat);
    }

    [Fact]
    public void TeardownOutput_drops_usable_area_and_association_maps()
    {
        var (svc, bind, _, usable) = Build();
        bind.LayerShellOutputByOutput[Output] = LsOutput;
        bind.OutputByLayerShellOutput[LsOutput] = Output;
        usable.Set(Output, 0, 30, 1920, 1050);

        svc.TeardownOutput(Output);

        Assert.False(usable.TryGet(Output, out _));
        Assert.False(bind.LayerShellOutputByOutput.ContainsKey(Output));
        Assert.False(bind.OutputByLayerShellOutput.ContainsKey(LsOutput));
    }

    [Fact]
    public void TeardownOutput_without_subobject_still_drops_usable_area()
    {
        var (svc, bind, _, usable) = Build();
        usable.Set(Output, 0, 0, 100, 100);

        svc.TeardownOutput(Output);

        Assert.False(usable.TryGet(Output, out _));
        Assert.Empty(bind.LayerShellOutputByOutput);
    }

    [Fact]
    public void Zero_proxies_are_no_ops()
    {
        var (svc, bind, focus, usable) = Build();

        svc.TeardownSeat(IntPtr.Zero);
        svc.TeardownOutput(IntPtr.Zero);

        Assert.Empty(bind.LayerShellSeatBySeat);
        Assert.Empty(bind.LayerShellOutputByOutput);
        Assert.False(focus.IsFocusLocked(IntPtr.Zero));
        Assert.False(usable.TryGet(IntPtr.Zero, out _));
    }
}
