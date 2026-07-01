using System;
using System.Collections.Generic;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Dispatch.Services;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Focus;
using Aqueous.Features.Input;
using Aqueous.Features.Layout;
using Aqueous.Features.Rules;
using Aqueous.Features.State;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Dispatch.Services;

public sealed unsafe class WindowEventServiceFocusTests
{
    private static readonly IntPtr Workspace = new(0x1000);

    [Fact]
    public void ClosedFocusedChildWindow_FocusesParentWhenParentStillExists()
    {
        var fixture = Build();
        var parent = new IntPtr(0x2000);
        var child = new IntPtr(0x3000);
        fixture.Windows.Entries[parent] = new WindowEntry { Proxy = parent, Workspace = Workspace };
        fixture.Windows.Entries[child] = new WindowEntry { Proxy = child, ParentProxy = parent, Workspace = Workspace };
        fixture.Focused.Current = child;

        fixture.Service.HandleEvent(child, RiverProtocolOpcodes.Window.Closed, null);

        Assert.Equal(1, fixture.Focus.ClearFocusedHandleCalls);
        Assert.Equal(parent, fixture.Focus.LastRequestedFocus);
        Assert.Equal(0, fixture.Focus.FocusAnyOtherWithWorkspaceCalls);
    }

    [Fact]
    public void ClosedFocusedWindowWithoutParent_RepairsFocusWithCapturedWorkspace()
    {
        var fixture = Build();
        var closed = new IntPtr(0x3000);
        fixture.Windows.Entries[closed] = new WindowEntry { Proxy = closed, Workspace = Workspace };
        fixture.Focused.Current = closed;

        fixture.Service.HandleEvent(closed, RiverProtocolOpcodes.Window.Closed, null);

        Assert.Equal(1, fixture.Focus.ClearFocusedHandleCalls);
        Assert.Equal(1, fixture.Focus.FocusAnyOtherWithWorkspaceCalls);
        Assert.Equal(closed, fixture.Focus.LastAvoidedWindow);
        Assert.Equal(Workspace, fixture.Focus.LastWorkspace);
    }

    [Fact]
    public void ClosedUnfocusedWindow_DoesNotRepairFocus()
    {
        var fixture = Build();
        var focused = new IntPtr(0x2000);
        var closed = new IntPtr(0x3000);
        fixture.Windows.Entries[focused] = new WindowEntry { Proxy = focused, Workspace = Workspace };
        fixture.Windows.Entries[closed] = new WindowEntry { Proxy = closed, Workspace = Workspace };
        fixture.Focused.Current = focused;

        fixture.Service.HandleEvent(closed, RiverProtocolOpcodes.Window.Closed, null);

        Assert.Equal(0, fixture.Focus.ClearFocusedHandleCalls);
        Assert.Equal(0, fixture.Focus.FocusAnyOtherWithWorkspaceCalls);
        Assert.Equal(IntPtr.Zero, fixture.Focus.LastRequestedFocus);
    }

    [Fact]
    public void ParentEvent_FocusesTransientChild()
    {
        var fixture = Build();
        var parent = new IntPtr(0x2000);
        var child = new IntPtr(0x3000);
        fixture.Windows.Entries[parent] = new WindowEntry { Proxy = parent, Workspace = Workspace, X = 100, Y = 100, W = 1000, H = 800 };
        fixture.Windows.Entries[child] = new WindowEntry { Proxy = child, Workspace = Workspace };

        WlArgument* args = stackalloc WlArgument[1];
        args[0].o = parent;
        fixture.Service.HandleEvent(child, RiverProtocolOpcodes.Window.Parent, args);

        Assert.Equal(parent, fixture.Windows.Entries[child].ParentProxy);
        Assert.True(fixture.Windows.Entries[child].Floating);
        Assert.True(fixture.Windows.Entries[child].HasFloatRect);
        Assert.Equal(child, fixture.Focus.LastRequestedFocus);
    }

    [Fact]
    public void ParentEvent_InheritsParentWorkspaceAndOutput()
    {
        var fixture = Build();
        var parent = new IntPtr(0x2000);
        var child = new IntPtr(0x3000);
        var output = new IntPtr(0x4000);
        fixture.Windows.Entries[parent] = new WindowEntry { Proxy = parent, Workspace = Workspace, Output = output, X = 100, Y = 100, W = 1000, H = 800 };
        fixture.Windows.Entries[child] = new WindowEntry { Proxy = child };

        WlArgument* args = stackalloc WlArgument[1];
        args[0].o = parent;
        fixture.Service.HandleEvent(child, RiverProtocolOpcodes.Window.Parent, args);

        Assert.Equal(Workspace, fixture.Windows.Entries[child].Workspace);
        Assert.Equal(output, fixture.Windows.Entries[child].Output);
        Assert.Equal(child, fixture.Focus.LastRequestedFocus);
    }

    [Fact]
    public void ClosedWindow_CancelsPendingPointerFocus()
    {
        var fixture = Build();
        var closed = new IntPtr(0x3000);
        // Unfocused window: cancellation must still fire (it is unconditional), because a pending
        // delayed focus-follows-mouse focus can target a window that is not currently focused.
        fixture.Windows.Entries[closed] = new WindowEntry { Proxy = closed, Workspace = Workspace };

        fixture.Service.HandleEvent(closed, RiverProtocolOpcodes.Window.Closed, null);

        Assert.Equal(1, fixture.Canceller.CancelPendingPointerFocusCalls);
    }

    private static (WindowEventService Service, WindowRegistry Windows, FocusedWindowTracker Focused, RecordingFocusService Focus, RecordingPointerFocusCanceller Canceller) Build()
    {
        var windows = new WindowRegistry();
        var focus = new RecordingFocusService();
        var focused = new FocusedWindowTracker();
        var canceller = new RecordingPointerFocusCanceller();
        var stateController = new WindowStateController(new NoopWindowStateHost(), new ScratchpadRegistry());

        var service = new WindowEventService(
            windows,
            new WindowStateStore(),
            new OutputFullscreenMap(),
            new PrevFullscreenStore(),
            new DragStateStore(),
            new PendingFocusStore(),
            focus,
            focused,
            stateController,
            new NoopLayoutProposer(),
            new NoopManagerRequestSender(),
            new WindowRuleEngine(),
            canceller);

        return (service, windows, focused, focus, canceller);
    }

    private sealed class RecordingFocusService : IFocusService
    {
        public int ClearFocusedHandleCalls { get; private set; }
        public int FocusAnyOtherWithWorkspaceCalls { get; private set; }
        public IntPtr LastRequestedFocus { get; private set; }
        public IntPtr LastAvoidedWindow { get; private set; }
        public IntPtr LastWorkspace { get; private set; }

        public IntPtr FocusedWindow => IntPtr.Zero;
        public bool TryGetFocusedAlive(out IntPtr proxy)
        {
            proxy = IntPtr.Zero;
            return false;
        }
        public void SetFocusedWindow(IntPtr windowProxy, IntPtr seatProxy) { }
        public void RequestFocus(IntPtr windowProxy) => LastRequestedFocus = windowProxy;
        public void ClearFocus() { }
        public void FocusAnyOtherWindow(IntPtr avoid) => LastAvoidedWindow = avoid;
        public void FocusAnyOtherWindow(IntPtr avoid, IntPtr workspace)
        {
            FocusAnyOtherWithWorkspaceCalls++;
            LastAvoidedWindow = avoid;
            LastWorkspace = workspace;
        }
        public void CycleFocus() { }
        public void HandleDirectionalFocus(FocusDirection dir) { }
        public void SetFocusedShellSurface(IntPtr shellSurfaceProxy, IntPtr seatProxy) { }
        public void InvalidateShellSurface(IntPtr shellSurfaceProxy) { }
        public void ClearFocusedHandle() => ClearFocusedHandleCalls++;
        public void ReassertFocusAfterLayerRelease() { }
        public void RepairFocusAfterTagChange() { }
    }

    private sealed class RecordingPointerFocusCanceller : IPointerFocusCanceller
    {
        public int CancelPendingPointerFocusCalls { get; private set; }

        public void CancelPendingPointerFocus() => CancelPendingPointerFocusCalls++;
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
            IReadOnlyList<WindowEntryView> snapshot, int workspaceNumber) => null;
    }

    private sealed class NoopManagerRequestSender : IManagerRequestSender
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
