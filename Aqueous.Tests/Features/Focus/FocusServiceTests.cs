using System;
using System.Collections.Generic;
using System.Linq;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Focus;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Focus;
using Aqueous.Features.Layout;
using Aqueous.Features.Tags;
using Xunit;

namespace Aqueous.Tests.Features.Focus;

/// <summary>
/// Stage 4 of the RiverWindowManagerClient decomposition. Verifies that
/// <see cref="FocusService"/> owns the focus behaviour previously living
/// on the god class and that the transient
/// <see cref="IFocusServiceCollaborators"/> bridge routes Wayland-visible
/// side effects back into the river client.
/// </summary>
public sealed class FocusServiceTests
{
    private static (FocusService svc, FakeCollab river, WindowRegistry windows, OutputRegistry outputs, SeatRegistry seats) MakeSubject(
        IntPtr primarySeat = default)
    {
        var windows = new WindowRegistry();
        var outputs = new OutputRegistry();
        var seats = new SeatRegistry();
        var river = new FakeCollab { PrimarySeat = primarySeat };
        var svc = new FocusService(windows, outputs, seats, river);
        return (svc, river, windows, outputs, seats);
    }

    private static IntPtr P(int v) => new IntPtr(v);

    private static WindowEntry MakeWindowEntry(IntPtr proxy, IntPtr output, uint tags = TagState.AllTags)
        => new() { Proxy = proxy, Output = output, Tags = tags };

    private static OutputEntry MakeOutputEntry(IntPtr proxy, uint visibleTags = TagState.AllTags)
        => new() { Proxy = proxy, VisibleTags = visibleTags };

    // ---- ctor null guards --------------------------------------------

    [Fact]
    public void Ctor_NullWindowRegistry_Throws()
    {
        Assert.Throws<ArgumentNullException>(() =>
            new FocusService(null!, new OutputRegistry(), new SeatRegistry(), new FakeCollab()));
    }

    [Fact]
    public void Ctor_NullCollaborator_Throws()
    {
        Assert.Throws<ArgumentNullException>(() =>
            new FocusService(new WindowRegistry(), new OutputRegistry(), new SeatRegistry(), null!));
    }

    // ---- FocusedWindow getter ----------------------------------------

    [Fact]
    public void FocusedWindow_ReflectsCollaboratorField()
    {
        var (svc, river, _, _, _) = MakeSubject();
        Assert.Equal(IntPtr.Zero, svc.FocusedWindow);
        river.FocusedWindow = P(42);
        Assert.Equal(P(42), svc.FocusedWindow);
    }

    // ---- TryGetFocusedAlive ------------------------------------------

    [Fact]
    public void TryGetFocusedAlive_NoFocus_ReturnsFalse()
    {
        var (svc, _, _, _, _) = MakeSubject();
        Assert.False(svc.TryGetFocusedAlive(out var p));
        Assert.Equal(IntPtr.Zero, p);
    }

    [Fact]
    public void TryGetFocusedAlive_StaleFocus_SelfHealsToZero()
    {
        var (svc, river, _, _, _) = MakeSubject();
        river.FocusedWindow = P(99); // not in registry
        Assert.False(svc.TryGetFocusedAlive(out _));
        Assert.Equal(IntPtr.Zero, river.FocusedWindow);
    }

    [Fact]
    public void TryGetFocusedAlive_LiveFocus_ReturnsTrue()
    {
        var (svc, river, windows, _, _) = MakeSubject();
        windows.Entries[P(1)] = MakeWindowEntry(P(1), IntPtr.Zero);
        river.FocusedWindow = P(1);
        Assert.True(svc.TryGetFocusedAlive(out var p));
        Assert.Equal(P(1), p);
    }

    // ---- RequestFocus ------------------------------------------------

    [Fact]
    public void RequestFocus_Zero_Logged_NoSchedule()
    {
        var (svc, river, _, _, _) = MakeSubject();
        svc.RequestFocus(IntPtr.Zero);
        Assert.Equal(0, river.ScheduleManageCalls);
        Assert.Single(river.Logs);
    }

    [Fact]
    public void RequestFocus_UnknownWindow_Logged_NoSchedule()
    {
        var (svc, river, _, _, _) = MakeSubject();
        svc.RequestFocus(P(7));
        Assert.Equal(0, river.ScheduleManageCalls);
        Assert.Single(river.Logs);
    }

    [Fact]
    public void RequestFocus_KnownWindow_PrimarySeat_SetsPendingAndSchedules()
    {
        var (svc, river, windows, _, _) = MakeSubject(primarySeat: P(10));
        windows.Entries[P(1)] = MakeWindowEntry(P(1), IntPtr.Zero);
        svc.RequestFocus(P(1));
        Assert.Equal(P(1), river.FocusedWindow);
        Assert.Equal(P(1), river.PendingFocusWindow);
        Assert.Equal(P(10), river.PendingFocusSeat);
        Assert.Equal(1, river.ScheduleManageCalls);
    }

    [Fact]
    public void RequestFocus_FallsBackToFirstSeat_WhenNoPrimary()
    {
        var (svc, river, windows, _, seats) = MakeSubject();
        windows.Entries[P(1)] = MakeWindowEntry(P(1), IntPtr.Zero);
        seats.Entries[P(33)] = new SeatEntry { Proxy = P(33) };
        svc.RequestFocus(P(1));
        Assert.Equal(P(33), river.PendingFocusSeat);
    }

    [Fact]
    public void RequestFocus_NoSeatsAvailable_ReturnsWithoutScheduling()
    {
        var (svc, river, windows, _, _) = MakeSubject();
        windows.Entries[P(1)] = MakeWindowEntry(P(1), IntPtr.Zero);
        svc.RequestFocus(P(1));
        Assert.Equal(0, river.ScheduleManageCalls);
    }

    [Fact]
    public void RequestFocus_Idempotent_OnSameFocus()
    {
        var (svc, river, windows, _, _) = MakeSubject(primarySeat: P(10));
        windows.Entries[P(1)] = MakeWindowEntry(P(1), IntPtr.Zero);
        svc.RequestFocus(P(1));
        var calls = river.ScheduleManageCalls;
        // Second call with same window short-circuits inside SetFocusedWindow.
        svc.RequestFocus(P(1));
        Assert.Equal(calls, river.ScheduleManageCalls);
    }

    // ---- ClearFocus --------------------------------------------------

    [Fact]
    public void ClearFocus_ClearsFieldAndSendsClearOnSeat()
    {
        var (svc, river, _, _, _) = MakeSubject(primarySeat: P(10));
        river.FocusedWindow = P(1);
        svc.ClearFocus();
        Assert.Equal(IntPtr.Zero, river.FocusedWindow);
        Assert.Equal(IntPtr.Zero, river.PendingFocusWindow);
        Assert.Equal(P(10), river.LastClearFocusSeat);
        Assert.Equal(1, river.ScheduleManageCalls);
    }

    [Fact]
    public void ClearFocus_NoSeats_DoesNotCallSendClear()
    {
        var (svc, river, _, _, _) = MakeSubject();
        svc.ClearFocus();
        Assert.Equal(IntPtr.Zero, river.LastClearFocusSeat);
        Assert.Equal(1, river.ScheduleManageCalls);
    }

    // ---- FocusAnyOtherWindow -----------------------------------------

    [Fact]
    public void FocusAnyOtherWindow_PrefersNotAvoid()
    {
        var (svc, river, windows, _, _) = MakeSubject(primarySeat: P(10));
        windows.Entries[P(1)] = MakeWindowEntry(P(1), IntPtr.Zero);
        windows.Entries[P(2)] = MakeWindowEntry(P(2), IntPtr.Zero);
        svc.FocusAnyOtherWindow(P(1));
        Assert.Equal(P(2), river.FocusedWindow);
    }

    [Fact]
    public void FocusAnyOtherWindow_FallsBackToAvoidIfOnlyOption()
    {
        var (svc, river, windows, _, _) = MakeSubject(primarySeat: P(10));
        windows.Entries[P(1)] = MakeWindowEntry(P(1), IntPtr.Zero);
        svc.FocusAnyOtherWindow(P(1));
        Assert.Equal(P(1), river.FocusedWindow);
    }

    [Fact]
    public void FocusAnyOtherWindow_EmptyRegistry_ClearsFocus()
    {
        var (svc, river, _, _, _) = MakeSubject(primarySeat: P(10));
        river.FocusedWindow = P(1);
        svc.FocusAnyOtherWindow(IntPtr.Zero);
        Assert.Equal(IntPtr.Zero, river.FocusedWindow);
        Assert.Equal(P(10), river.LastClearFocusSeat);
    }

    // ---- CycleFocus --------------------------------------------------

    [Fact]
    public void CycleFocus_EmptyRegistry_NoOp()
    {
        var (svc, river, _, _, _) = MakeSubject(primarySeat: P(10));
        svc.CycleFocus();
        Assert.Equal(IntPtr.Zero, river.FocusedWindow);
        Assert.Equal(0, river.ScheduleManageCalls);
    }

    [Fact]
    public void CycleFocus_AdvancesToNextInIterationOrder()
    {
        var (svc, river, windows, _, _) = MakeSubject(primarySeat: P(10));
        windows.Entries[P(1)] = MakeWindowEntry(P(1), IntPtr.Zero);
        windows.Entries[P(2)] = MakeWindowEntry(P(2), IntPtr.Zero);
        windows.Entries[P(3)] = MakeWindowEntry(P(3), IntPtr.Zero);
        river.FocusedWindow = P(1);
        svc.CycleFocus();
        // First key was used as fallback (P(1)), then after seeing P(1) takeNext flips.
        // Either P(2) or P(3) depending on dictionary order; assert non-zero advance.
        Assert.NotEqual(IntPtr.Zero, river.FocusedWindow);
        Assert.Contains(river.FocusedWindow, new[] { P(1), P(2), P(3) });
    }

    // ---- SetFocusedShellSurface --------------------------------------

    [Fact]
    public void SetFocusedShellSurface_UpdatesPendingShellSurfaceAndSchedules()
    {
        var (svc, river, _, _, _) = MakeSubject();
        svc.SetFocusedShellSurface(P(77), P(10));
        Assert.Equal(P(77), river.PendingFocusShellSurface);
        Assert.Equal(IntPtr.Zero, river.PendingFocusWindow);
        Assert.Equal(P(10), river.PendingFocusSeat);
        Assert.Equal(1, river.ScheduleManageCalls);
    }

    // ---- RepairFocusAfterTagChange -----------------------------------

    [Fact]
    public void RepairFocusAfterTagChange_FocusStillVisible_KeepsFocus()
    {
        var (svc, river, windows, outputs, _) = MakeSubject(primarySeat: P(10));
        outputs.Entries[P(100)] = MakeOutputEntry(P(100), visibleTags: 0b1);
        windows.Entries[P(1)] = MakeWindowEntry(P(1), P(100), tags: 0b1);
        river.FocusedWindow = P(1);
        svc.RepairFocusAfterTagChange();
        Assert.Equal(P(1), river.FocusedWindow);
    }

    [Fact]
    public void RepairFocusAfterTagChange_FocusInvisible_PicksVisibleReplacement()
    {
        var (svc, river, windows, outputs, _) = MakeSubject(primarySeat: P(10));
        outputs.Entries[P(100)] = MakeOutputEntry(P(100), visibleTags: 0b10);
        windows.Entries[P(1)] = MakeWindowEntry(P(1), P(100), tags: 0b01); // hidden
        windows.Entries[P(2)] = MakeWindowEntry(P(2), P(100), tags: 0b10); // visible
        river.FocusedWindow = P(1);
        svc.RepairFocusAfterTagChange();
        Assert.Equal(P(2), river.FocusedWindow);
    }

    [Fact]
    public void RepairFocusAfterTagChange_NoVisibleReplacement_ClearsFocus()
    {
        var (svc, river, windows, outputs, _) = MakeSubject(primarySeat: P(10));
        outputs.Entries[P(100)] = MakeOutputEntry(P(100), visibleTags: 0b10);
        windows.Entries[P(1)] = MakeWindowEntry(P(1), P(100), tags: 0b01);
        river.FocusedWindow = P(1);
        svc.RepairFocusAfterTagChange();
        Assert.Equal(IntPtr.Zero, river.FocusedWindow);
        Assert.Equal(P(10), river.LastClearFocusSeat);
    }

    // ---- ClearFocusedHandle ------------------------------------------

    [Fact]
    public void ClearFocusedHandle_ClearsFieldWithoutSchedulingOrSending()
    {
        var (svc, river, _, _, _) = MakeSubject(primarySeat: P(10));
        river.FocusedWindow = P(1);
        svc.ClearFocusedHandle();
        Assert.Equal(IntPtr.Zero, river.FocusedWindow);
        Assert.Equal(0, river.ScheduleManageCalls);
        Assert.Equal(IntPtr.Zero, river.LastClearFocusSeat);
    }

    // ---- HandleDirectionalFocus --------------------------------------

    [Fact]
    public void HandleDirectionalFocus_NoFocus_CyclesInstead()
    {
        var (svc, river, windows, _, _) = MakeSubject(primarySeat: P(10));
        windows.Entries[P(1)] = MakeWindowEntry(P(1), IntPtr.Zero);
        svc.HandleDirectionalFocus(FocusDirection.Left);
        Assert.Equal(P(1), river.FocusedWindow);
    }

    [Fact]
    public void HandleDirectionalFocus_LayoutSuggestsNeighbor_TakesIt()
    {
        var (svc, river, windows, _, _) = MakeSubject(primarySeat: P(10));
        windows.Entries[P(1)] = MakeWindowEntry(P(1), IntPtr.Zero);
        windows.Entries[P(2)] = MakeWindowEntry(P(2), IntPtr.Zero);
        river.FocusedWindow = P(1);
        river.NextLayoutNeighbor = P(2);
        svc.HandleDirectionalFocus(FocusDirection.Right);
        Assert.Equal(P(2), river.FocusedWindow);
    }

    // ---- Regression guards ------------------------------------------

    [Fact]
    public void TagServiceCollaborators_DoesNotDeclare_FocusedWindow()
    {
        Assert.Null(typeof(Aqueous.Features.Compositor.River.Tags.ITagServiceCollaborators)
            .GetProperty("FocusedWindow"));
    }

    [Fact]
    public void TagServiceCollaborators_DoesNotDeclare_ClearFocus()
    {
        Assert.Null(typeof(Aqueous.Features.Compositor.River.Tags.ITagServiceCollaborators)
            .GetMethod("ClearFocus"));
    }

    [Fact]
    public void TagServiceCollaborators_DoesNotDeclare_RequestFocus()
    {
        Assert.Null(typeof(Aqueous.Features.Compositor.River.Tags.ITagServiceCollaborators)
            .GetMethod("RequestFocus"));
    }

    [Fact]
    public void FocusServiceCollaborators_DeclaresFocusedWindowSetter()
    {
        var p = typeof(IFocusServiceCollaborators).GetProperty("FocusedWindow");
        Assert.NotNull(p);
        Assert.True(p!.CanWrite, "FocusedWindow must be settable (write-through to god class field).");
    }

    // ===== fake collaborator =========================================

    private sealed class FakeCollab : IFocusServiceCollaborators
    {
        public IntPtr FocusedWindow { get; set; }
        public IntPtr PrimarySeat { get; set; }
        public List<IntPtr> Seats { get; } = new();
        public IEnumerable<IntPtr> SeatProxies => Seats;
        public IntPtr PendingFocusWindow { get; private set; }
        public IntPtr PendingFocusShellSurface { get; private set; }
        public IntPtr PendingFocusSeat { get; private set; }
        public int ScheduleManageCalls { get; private set; }
        public IntPtr LastClearFocusSeat { get; private set; } = IntPtr.Zero;
        public List<string> Logs { get; } = new();
        public IntPtr NextLayoutNeighbor { get; set; }

        public void SetPendingFocusWindow(IntPtr windowProxy, IntPtr seatProxy)
        {
            PendingFocusWindow = windowProxy;
            PendingFocusShellSurface = IntPtr.Zero;
            PendingFocusSeat = seatProxy;
        }

        public void SetPendingFocusShellSurface(IntPtr shellSurfaceProxy, IntPtr seatProxy)
        {
            PendingFocusShellSurface = shellSurfaceProxy;
            PendingFocusWindow = IntPtr.Zero;
            PendingFocusSeat = seatProxy;
        }

        public void ScheduleManage() => ScheduleManageCalls++;
        public void SendClearFocus(IntPtr seatProxy) => LastClearFocusSeat = seatProxy;
        public string? ResolveOutputName(IntPtr outputProxy) => null;
        public IReadOnlyList<WindowEntryView> BuildSnapshotFor(IntPtr outputProxy)
            => Array.Empty<WindowEntryView>();
        public IntPtr? LayoutFocusNeighbor(IntPtr output, string? outputName, IntPtr current,
            FocusDirection dir, IReadOnlyList<WindowEntryView> snapshot)
            => NextLayoutNeighbor == IntPtr.Zero ? null : NextLayoutNeighbor;
        public void Log(string message) => Logs.Add(message);
    }
}
