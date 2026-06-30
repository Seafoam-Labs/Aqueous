using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Dispatch.Services;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Focus;
using Aqueous.Features.Layout;
using Aqueous.Features.State;
using Aqueous.Features.Workspaces;
using Xunit;

namespace Aqueous.Tests.Features.Focus;

public sealed class FocusServiceShellSurfaceFocusTests
{
    private static readonly IntPtr Seat = new(0x5EA7);
    private static readonly IntPtr Window = new(0x301D);
    private static readonly IntPtr ShellSurface = new(0x51E11);
    private static readonly IntPtr OtherShellSurface = new(0x51E12);

    [Fact]
    public void SetFocusedShellSurfaceClearsFocusedWindowForFocusSensitiveOpacity()
    {
        var fixture = Build();
        fixture.Windows.Entries[Window] = new WindowEntry { Proxy = Window };
        fixture.Service.SetFocusedWindow(Window, Seat);

        fixture.Service.SetFocusedShellSurface(ShellSurface, Seat);

        Assert.Equal(IntPtr.Zero, fixture.Focused.Current);
        Assert.Equal(IntPtr.Zero, fixture.Pending.Window);
        Assert.Equal(ShellSurface, fixture.Pending.ShellSurface);

        var opacityCfg = new OpacitySpec(true, 0.85, true, 1.0, 0.75);
        Assert.Equal(
            0.75,
            ManagerEventService.ResolveWindowOpacity(
                fixture.Windows.Entries[Window],
                Window,
                fixture.Focused.Current,
                opacityCfg));
    }

    [Fact]
    public void ReassertFocusAfterLayerReleaseRestoresWindowFocusedBeforeShellSurface()
    {
        var fixture = Build();
        fixture.Windows.Entries[Window] = new WindowEntry { Proxy = Window };
        fixture.Service.SetFocusedWindow(Window, Seat);

        fixture.Service.SetFocusedShellSurface(ShellSurface, Seat);
        fixture.Service.SetFocusedShellSurface(OtherShellSurface, Seat);

        fixture.Service.ReassertFocusAfterLayerRelease();

        Assert.Equal(Window, fixture.Focused.Current);
        Assert.Equal(Window, fixture.Pending.Window);
        Assert.Equal(IntPtr.Zero, fixture.Pending.ShellSurface);
    }

    private static (FocusService Service, WindowRegistry Windows, FocusedWindowTracker Focused, PendingFocusStore Pending) Build()
    {
        var windows = new WindowRegistry();
        var outputs = new OutputRegistry();
        var seats = new SeatRegistry();
        var focused = new FocusedWindowTracker();
        var pending = new PendingFocusStore();
        var primarySeat = new PrimarySeatTracker { Current = Seat };
        var sender = new CountingManagerRequestSender();
        var proposer = new NoopLayoutProposer();
        var stateController = new Lazy<WindowStateController>(
            () => new WindowStateController(new NoopWindowStateHost(), new ScratchpadRegistry()));
        var layerFocus = new LayerShellFocusState();

        var service = new FocusService(
            windows,
            outputs,
            seats,
            focused,
            pending,
            primarySeat,
            sender,
            proposer,
            stateController,
            layerFocus,
            new WorkspaceStore());

        return (service, windows, focused, pending);
    }

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
            IntPtr output,
            string? outputName,
            IntPtr current,
            FocusDirection dir,
            IReadOnlyList<WindowEntryView> snapshot,
            int workspaceNumber) => null;
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
