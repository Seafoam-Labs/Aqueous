using System;
using System.Collections.Generic;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Focus;
using Aqueous.Features.Layout;
using Aqueous.Features.State;
using Xunit;

namespace Aqueous.Tests.Features.Focus;

/// <summary>
/// When a seat is in <see cref="LayerFocusMode.Exclusive"/> the WM must suppress its own
/// focus-change requests (the compositor ignores them anyway; suppressing avoids spurious manage
/// churn). When the seat is not locked, focus changes flow normally.
/// <para>
/// The <see cref="Lazy{T}"/> <c>WindowStateController</c> is wired to throw: the exclusive-lock
/// guard in <see cref="FocusService.RequestFocus"/> returns <em>before</em> it would ever be
/// dereferenced, so a throwing lazy proves the suppression short-circuits early rather than merely
/// happening to no-op later.
/// </para>
/// </summary>
public sealed class FocusServiceLayerShellSuppressionTests
{
    private static readonly IntPtr Seat = new(0x5EA7);
    private static readonly IntPtr Window = new(0x301D);

    // Counts ScheduleManage so a suppressed focus change can be distinguished from an applied one.
    private sealed class CountingManagerRequestSender : IManagerRequestSender
    {
        public int ScheduleManageCalls { get; private set; }

        public void SendManagerRequest(uint opcode) { }
        public void ScheduleManage() => ScheduleManageCalls++;
        public bool InsideManageSequence { get; set; }
        public void Init(IntPtr managerProxy, IntPtr display) { }
        public bool IsBound => false;
        public void Reset() { }
        public void SetPumpThread(int managedThreadId) { }
        public void DrainPumpQueue() { }
    }

    // The suppression paths under test never consult the layout proposer; any call is a bug.
    private sealed class ThrowingLayoutProposer : ILayoutProposer
    {
        public void ProposeForArea(IntPtr output, string? outputName, Rect usableArea)
            => throw new InvalidOperationException("layout proposer must not be touched");

        public void ProposeForArea(IntPtr output, string? outputName, Rect outputRect, Rect usableArea)
            => throw new InvalidOperationException("layout proposer must not be touched");

        public bool IsFloatLayoutActive()
            => throw new InvalidOperationException("layout proposer must not be touched");

        public bool IsFloatLayoutActive(IntPtr output)
            => throw new InvalidOperationException("layout proposer must not be touched");

        public IReadOnlyList<WindowEntryView> BuildSnapshotFor(IntPtr output)
            => throw new InvalidOperationException("layout proposer must not be touched");

        public string? ResolveOutputName(IntPtr output)
            => throw new InvalidOperationException("layout proposer must not be touched");

        public IntPtr? LayoutFocusNeighbor(
            IntPtr output, string? outputName, IntPtr current, FocusDirection dir,
            IReadOnlyList<WindowEntryView> snapshot, uint visibleTags)
            => throw new InvalidOperationException("layout proposer must not be touched");
    }

    private static (FocusService svc, CountingManagerRequestSender sender,
        FocusedWindowTracker focused, LayerShellFocusState layerFocus, WindowRegistry windows) Build()
    {
        var windows = new WindowRegistry();
        var outputs = new OutputRegistry();
        var seats = new SeatRegistry();
        var focused = new FocusedWindowTracker();
        var pending = new PendingFocusStore();
        var primarySeat = new PrimarySeatTracker { Current = Seat };
        var sender = new CountingManagerRequestSender();
        var proposer = new ThrowingLayoutProposer();
        // Must throw if ever accessed; the exclusive-lock guard returns before it is dereferenced.
        var stateController = new Lazy<WindowStateController>(
            () => throw new InvalidOperationException("state controller must not be resolved"));
        var layerFocus = new LayerShellFocusState();

        var svc = new FocusService(
            windows, outputs, seats, focused, pending, primarySeat,
            sender, proposer, stateController, layerFocus);

        return (svc, sender, focused, layerFocus, windows);
    }

    [Fact]
    public void SetFocusedWindow_suppressed_when_seat_exclusively_locked()
    {
        var (svc, sender, focused, layerFocus, _) = Build();
        layerFocus.SetExclusive(Seat);

        svc.SetFocusedWindow(Window, Seat);

        Assert.Equal(0, sender.ScheduleManageCalls);
        Assert.Equal(IntPtr.Zero, focused.Current);
    }

    [Fact]
    public void SetFocusedWindow_applies_when_seat_not_locked()
    {
        var (svc, sender, focused, _, _) = Build();

        svc.SetFocusedWindow(Window, Seat);

        Assert.Equal(1, sender.ScheduleManageCalls);
        Assert.Equal(Window, focused.Current);
    }

    [Fact]
    public void SetFocusedWindow_applies_when_seat_non_exclusive()
    {
        var (svc, sender, focused, layerFocus, _) = Build();
        layerFocus.SetNonExclusive(Seat);

        svc.SetFocusedWindow(Window, Seat);

        Assert.Equal(1, sender.ScheduleManageCalls);
        Assert.Equal(Window, focused.Current);
    }

    [Fact]
    public void RequestFocus_suppressed_when_seat_exclusively_locked()
    {
        var (svc, sender, focused, layerFocus, windows) = Build();
        windows.Entries[Window] = new WindowEntry { Proxy = Window };
        layerFocus.SetExclusive(Seat);

        // Must not throw (the throwing Lazy<WindowStateController> proves the guard short-circuits
        // before the restore path) and must not schedule a manage cycle.
        svc.RequestFocus(Window);

        Assert.Equal(0, sender.ScheduleManageCalls);
        Assert.Equal(IntPtr.Zero, focused.Current);
    }

    [Fact]
    public void RequestFocus_focus_none_after_exclusive_restores_normal_flow()
    {
        var (svc, sender, focused, layerFocus, _) = Build();
        layerFocus.SetExclusive(Seat);
        layerFocus.SetNone(Seat);

        // focus_none clears the lock, so a subsequent focus request applies normally.
        svc.SetFocusedWindow(Window, Seat);

        Assert.Equal(1, sender.ScheduleManageCalls);
        Assert.Equal(Window, focused.Current);
    }
}
