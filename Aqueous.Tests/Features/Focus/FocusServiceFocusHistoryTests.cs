using System;
using System.Collections.Generic;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Focus;
using Aqueous.Features.Layout;
using Aqueous.Features.State;
using Aqueous.Features.Workspaces;
using Xunit;

namespace Aqueous.Tests.Features.Focus;

public sealed class FocusServiceFocusHistoryTests
{
    private static readonly IntPtr Seat = new(0x5EA7);
    private static readonly IntPtr Workspace = new(0x1000);
    private static readonly IntPtr OtherWorkspace = new(0x2000);

    [Fact]
    public void FocusAnyOtherWindow_UsesMruWindowInSameWorkspace()
    {
        var fixture = Build();
        var first = new IntPtr(0x3000);
        var mru = new IntPtr(0x4000);
        var closed = new IntPtr(0x5000);
        fixture.Windows.Entries[first] = Window(first, Workspace);
        fixture.Windows.Entries[mru] = Window(mru, Workspace);
        fixture.Windows.Entries[closed] = Window(closed, Workspace);

        fixture.Service.SetFocusedWindow(first, Seat);
        fixture.Service.SetFocusedWindow(mru, Seat);
        fixture.Service.SetFocusedWindow(closed, Seat);
        fixture.Windows.Entries.TryRemove(closed, out _);
        fixture.Focused.Current = IntPtr.Zero;
        fixture.Pending.Clear();

        fixture.Service.FocusAnyOtherWindow(closed, Workspace);

        Assert.Equal(mru, fixture.Focused.Current);
        Assert.Equal(mru, fixture.Pending.Window);
    }

    [Fact]
    public void FocusAnyOtherWindow_DoesNotFocusDifferentWorkspace()
    {
        var fixture = Build();
        var otherWorkspaceWindow = new IntPtr(0x3000);
        var closed = new IntPtr(0x4000);
        fixture.Windows.Entries[otherWorkspaceWindow] = Window(otherWorkspaceWindow, OtherWorkspace);
        fixture.Windows.Entries[closed] = Window(closed, Workspace);

        fixture.Service.SetFocusedWindow(otherWorkspaceWindow, Seat);
        fixture.Service.SetFocusedWindow(closed, Seat);
        fixture.Windows.Entries.TryRemove(closed, out _);
        fixture.Focused.Current = IntPtr.Zero;
        fixture.Pending.Clear();

        fixture.Service.FocusAnyOtherWindow(closed, Workspace);

        Assert.Equal(IntPtr.Zero, fixture.Focused.Current);
        Assert.Equal(IntPtr.Zero, fixture.Pending.Window);
    }

    [Fact]
    public void FocusAnyOtherWindow_FallsBackWhenHistoryEmpty()
    {
        var fixture = Build();
        var fallback = new IntPtr(0x3000);
        var closed = new IntPtr(0x4000);
        fixture.Windows.Entries[fallback] = Window(fallback, Workspace);

        fixture.Service.FocusAnyOtherWindow(closed, Workspace);

        Assert.Equal(fallback, fixture.Focused.Current);
        Assert.Equal(fallback, fixture.Pending.Window);
    }

    [Fact]
    public void RepairFocusAfterTagChange_UsesMruVisibleWindowInSameWorkspace()
    {
        var fixture = Build();
        var output = new IntPtr(0x7000);
        var oldVisible = new IntPtr(0x3000);
        var mruVisible = new IntPtr(0x4000);
        var nowHidden = new IntPtr(0x5000);
        fixture.Outputs.Entries[output] = new OutputEntry { Proxy = output, VisibleTags = 0b10 };
        fixture.Windows.Entries[oldVisible] = Window(oldVisible, Workspace, output, 0b10);
        fixture.Windows.Entries[mruVisible] = Window(mruVisible, Workspace, output, 0b10);
        fixture.Windows.Entries[nowHidden] = Window(nowHidden, Workspace, output, 0b01);

        fixture.Service.SetFocusedWindow(oldVisible, Seat);
        fixture.Service.SetFocusedWindow(mruVisible, Seat);
        fixture.Service.SetFocusedWindow(nowHidden, Seat);

        fixture.Service.RepairFocusAfterTagChange();

        Assert.Equal(mruVisible, fixture.Focused.Current);
        Assert.Equal(mruVisible, fixture.Pending.Window);
    }

    private static (FocusService Service, WindowRegistry Windows, OutputRegistry Outputs, FocusedWindowTracker Focused, PendingFocusStore Pending) Build()
    {
        var windows = new WindowRegistry();
        var outputs = new OutputRegistry();
        var seats = new SeatRegistry();
        var focused = new FocusedWindowTracker();
        var pending = new PendingFocusStore();
        var primarySeat = new PrimarySeatTracker { Current = Seat };
        var sender = new CountingManagerRequestSender();
        var proposer = new NoopLayoutProposer();
        var stateController = new Lazy<WindowStateController>(() => new WindowStateController(new NoopWindowStateHost(), new ScratchpadRegistry()));
        var layerFocus = new LayerShellFocusState();

        var service = new FocusService(
            windows, outputs, seats, focused, pending, primarySeat,
            sender, proposer, stateController, layerFocus, new WorkspaceStore());

        return (service, windows, outputs, focused, pending);
    }

    private static WindowEntry Window(IntPtr proxy, IntPtr workspace, IntPtr output = default, uint tags = 1) => new()
    {
        Proxy = proxy,
        Workspace = workspace,
        Output = output,
        Tags = tags
    };

    private sealed class CountingManagerRequestSender : IManagerRequestSender
    {
        public void SendManagerRequest(uint opcode) { }
        public void ScheduleManage() { }
        public bool InsideManageSequence { get; set; }
        public void Init(IntPtr managerProxy, IntPtr display) { }
        public bool IsBound => false;
        public void Reset() { }
        public void SetPumpThread(int managedThreadId) { }
        public void DrainPumpQueue() { }
        public bool IsOnPumpThread => true;
        public void Post(Action action) => action();
        public void SetSeat(IntPtr seat) { }
        public void SuppressPointerConstraints(bool pressed) { }
    }

    private sealed class NoopLayoutProposer : ILayoutProposer
    {
        public void ProposeForArea(IntPtr output, string? outputName, Rect usableArea) { }
        public void ProposeForArea(IntPtr output, string? outputName, Rect outputRect, Rect usableArea) { }
        public bool IsFloatLayoutActive() => false;
        public bool IsFloatLayoutActive(IntPtr output) => false;
        public IReadOnlyList<WindowEntryView> BuildSnapshotFor(IntPtr output) => Array.Empty<WindowEntryView>();
        public string? ResolveOutputName(IntPtr output) => null;
        public IntPtr? LayoutFocusNeighbor(
            IntPtr output, string? outputName, IntPtr current, FocusDirection dir,
            IReadOnlyList<WindowEntryView> snapshot, uint visibleTags) => null;
    }

    private sealed class NoopWindowStateHost : IWindowStateHost
    {
        public WindowStateData? Get(WindowProxy window) => null;
        public WindowProxy FocusedWindow => WindowProxy.Zero;
        public OutputProxy FocusedOutput => OutputProxy.Zero;
        public Rect OutputRect(OutputProxy output) => default;
        public Rect UsableArea(OutputProxy output) => default;
        public WindowProxy GetFullscreenWindow(OutputProxy output) => WindowProxy.Zero;
        public void SetFullscreenWindow(OutputProxy output, WindowProxy window) { }
        public void Focus(WindowProxy window) { }
        public void FocusNextOnOutput(OutputProxy output) { }
        public void RequestRender(OutputProxy output) { }
        public void EmitForeignToplevelFullscreen(WindowProxy window, OutputProxy output) { }
        public void EmitForeignToplevelUnfullscreen(WindowProxy window) { }
        public void Spawn(string command) { }
        public void InvalidateFloatRect(WindowProxy window) { }
        public void SetToplevelMaximizedState(WindowProxy window, bool maximized) { }
        public void Log(string message) { }
        public Rect CurrentGeometry(WindowProxy window) => default;
    }
}
