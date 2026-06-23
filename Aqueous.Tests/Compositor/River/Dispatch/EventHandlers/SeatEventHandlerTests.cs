using System.Linq;
using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Aqueous.Features.Bindings;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Focus;
using Aqueous.Features.Input;
using Aqueous.Features.Layout;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// Structural guards for <see cref="SeatEventHandler"/>. retired the class negative-shape pins
/// together with <c>RiverWindowManagerClient</c> itself.
/// </summary>
public sealed class SeatEventHandlerTests
{
    [Fact]
    public void SeatEventHandler_Implements_IEventHandler_With_Correct_Interface_Name()
    {
        Assert.Contains(typeof(IEventHandler), typeof(SeatEventHandler).GetInterfaces());
        Assert.True(typeof(SeatEventHandler).IsSealed);
    }

    [Fact]
    public void SeatEventHandler_Ctor_Takes_SeatInteractionService()
    {
        var ctor = typeof(SeatEventHandler).GetConstructors().Single();
        var p = ctor.GetParameters();
        Assert.Equal(6, p.Length);
        Assert.Equal(typeof(SeatInteractionService), p[4].ParameterType);
    }

    [Fact]
    public void ISeatHandlerCollaborators_Type_Deleted()
    {
        var asm = typeof(RiverCompositorHost).Assembly;
        var t = asm.GetType(
            "Aqueous.Features.Compositor.River.Dispatch.EventHandlers.ISeatHandlerCollaborators");
        Assert.Null(t);
    }

    [Fact]
    public void PointerEnter_FocusesImmediately_ForNonScrollingLayout()
    {
        var focus = new RecordingFocusService();
        var registry = new WindowRegistry();
        var service = CreateService(focus, registry, "tile", null);
        var window = registry.Track(new IntPtr(10));
        window.Output = new IntPtr(20);
        window.Tags = 1;

        service.HandlePointerEnterFocusFollow(window.Proxy, new IntPtr(30));

        Assert.Equal(window.Proxy, focus.FocusedWindow);
        Assert.Equal(1, focus.FocusCalls);
    }

    [Fact]
    public void PointerEnter_FocusesImmediately_ForScrollingWithoutDelay()
    {
        var focus = new RecordingFocusService();
        var registry = new WindowRegistry();
        var service = CreateService(focus, registry, "scrolling", null);
        var window = registry.Track(new IntPtr(11));
        window.Output = new IntPtr(21);
        window.Tags = 1;

        service.HandlePointerEnterFocusFollow(window.Proxy, new IntPtr(31));

        Assert.Equal(window.Proxy, focus.FocusedWindow);
        Assert.Equal(1, focus.FocusCalls);
    }

    [Fact]
    public async Task PointerEnter_DelaysFocus_ForScrollingWithDelay()
    {
        var focus = new RecordingFocusService();
        var registry = new WindowRegistry();
        var service = CreateService(focus, registry, "scrolling", "40");
        var window = registry.Track(new IntPtr(12));
        window.Output = new IntPtr(22);
        window.Tags = 1;

        service.HandlePointerEnterFocusFollow(window.Proxy, new IntPtr(32));

        Assert.Equal(IntPtr.Zero, focus.FocusedWindow);
        await Task.Delay(120);
        Assert.Equal(window.Proxy, focus.FocusedWindow);
        Assert.Equal(1, focus.FocusCalls);
    }

    [Fact]
    public async Task PointerEnter_CancelsPendingScrollingFocus_WhenAnotherWindowIsEntered()
    {
        var focus = new RecordingFocusService();
        var registry = new WindowRegistry();
        var service = CreateService(focus, registry, "scrolling", "80");
        var first = registry.Track(new IntPtr(13));
        var second = registry.Track(new IntPtr(14));
        first.Output = second.Output = new IntPtr(23);
        first.Tags = second.Tags = 1;

        service.HandlePointerEnterFocusFollow(first.Proxy, new IntPtr(33));
        await Task.Delay(20);
        service.HandlePointerEnterFocusFollow(second.Proxy, new IntPtr(33));
        await Task.Delay(140);

        Assert.Equal(second.Proxy, focus.FocusedWindow);
        Assert.Equal(1, focus.FocusCalls);
    }

    [Fact]
    public void PointerEnter_DoesNotFocusScrollingWindow_WhenMouseFocusWouldScrollPastLimit()
    {
        var focus = new RecordingFocusService(new IntPtr(15));
        var registry = new WindowRegistry();
        var service = CreateService(focus, registry, "scrolling", null, "0%");
        var first = registry.Track(focus.FocusedWindow);
        var second = registry.Track(new IntPtr(16));
        first.Output = second.Output = new IntPtr(24);
        first.Tags = second.Tags = 1;

        service.HandlePointerEnterFocusFollow(second.Proxy, new IntPtr(34));

        Assert.Equal(first.Proxy, focus.FocusedWindow);
        Assert.Equal(0, focus.FocusCalls);
    }

    [Fact]
    public void PointerEnter_FocusesScrollingWindow_WhenMouseFocusScrollIsWithinLimit()
    {
        var focus = new RecordingFocusService(new IntPtr(17));
        var registry = new WindowRegistry();
        var service = CreateService(focus, registry, "scrolling", null, "100%");
        var first = registry.Track(focus.FocusedWindow);
        var second = registry.Track(new IntPtr(18));
        first.Output = second.Output = new IntPtr(25);
        first.Tags = second.Tags = 1;

        service.HandlePointerEnterFocusFollow(second.Proxy, new IntPtr(35));

        Assert.Equal(second.Proxy, focus.FocusedWindow);
        Assert.Equal(1, focus.FocusCalls);
    }

    private static SeatInteractionService CreateService(
        RecordingFocusService focus,
        WindowRegistry registry,
        string layoutId,
        string? delayMs,
        string? maxScrollAmount = null)
    {
        var extra = new Dictionary<string, string>();
        if (delayMs != null)
        {
            extra["focus_follows_mouse_delay_ms"] = delayMs;
        }

        if (maxScrollAmount != null)
        {
            extra["focus_follows_mouse_max_scroll_amount"] = maxScrollAmount;
        }

        var config = new LayoutConfig
        {
            DefaultLayout = layoutId,
            Input = InputConfig.Default with { FocusFollowsMouse = true },
            PerLayoutOpts = new Dictionary<string, LayoutOptions>
            {
                ["scrolling"] = LayoutOptions.Default with { Extra = extra },
            },
        };

        return new SeatInteractionService(
            new DragStateStore(),
            registry,
            focus,
            new RegistryLayoutProposer(registry),
            new NullManagerRequestSender(),
            new LayoutController(new LayoutRegistry(), config),
            new WaylandBindSiteState(),
            new KeyBindingsRegistry(),
            new ShellSurfaceRegistry(),
            new NullLayerShellTeardownService());
    }

    private sealed class RecordingFocusService : IFocusService
    {
        public RecordingFocusService(IntPtr focusedWindow = default)
        {
            FocusedWindow = focusedWindow;
        }

        public IntPtr FocusedWindow { get; private set; }
        public int FocusCalls { get; private set; }
        public bool TryGetFocusedAlive(out IntPtr proxy) { proxy = FocusedWindow; return proxy != IntPtr.Zero; }
        public void SetFocusedWindow(IntPtr windowProxy, IntPtr seatProxy) { FocusedWindow = windowProxy; FocusCalls++; }
        public void RequestFocus(IntPtr windowProxy) => SetFocusedWindow(windowProxy, IntPtr.Zero);
        public void ClearFocus() => FocusedWindow = IntPtr.Zero;
        public void FocusAnyOtherWindow(IntPtr avoid) { }
        public void CycleFocus() { }
        public void HandleDirectionalFocus(FocusDirection dir) { }
        public void SetFocusedShellSurface(IntPtr shellSurfaceProxy, IntPtr seatProxy) { }
        public void InvalidateShellSurface(IntPtr shellSurfaceProxy) { }
        public void RepairFocusAfterTagChange() { }
        public void ClearFocusedHandle() => FocusedWindow = IntPtr.Zero;
        public void ReassertFocusAfterLayerRelease() { }
    }

    private sealed class RegistryLayoutProposer(WindowRegistry registry) : ILayoutProposer
    {
        public void ProposeForArea(IntPtr output, string? outputName, Rect usableArea) { }
        public void ProposeForArea(IntPtr output, string? outputName, Rect outputRect, Rect usableArea) { }
        public bool IsFloatLayoutActive() => false;
        public bool IsFloatLayoutActive(IntPtr output) => false;
        public IReadOnlyList<WindowEntryView> BuildSnapshotFor(IntPtr output)
        {
            var snapshot = new List<WindowEntryView>();
            foreach (var entry in registry.Entries.Values)
            {
                if (entry.Output == output)
                {
                    snapshot.Add(new WindowEntryView(
                        entry.Proxy,
                        entry.MinW,
                        entry.MinH,
                        entry.MaxW,
                        entry.MaxH,
                        entry.Floating,
                        false,
                        entry.Tags,
                        entry.Placement,
                        entry.WidthHint,
                        entry.HeightHint,
                        entry.LastFocusTick));
                }
            }

            snapshot.Sort((a, b) => a.Handle.ToInt64().CompareTo(b.Handle.ToInt64()));
            return snapshot;
        }
        public string? ResolveOutputName(IntPtr output) => null;
        public IntPtr? LayoutFocusNeighbor(IntPtr output, string? outputName, IntPtr current, FocusDirection dir, IReadOnlyList<WindowEntryView> snapshot, uint visibleTags) => null;
    }

    private sealed class NullManagerRequestSender : IManagerRequestSender
    {
        public bool InsideManageSequence { get; set; }
        public bool IsBound => false;
        public bool IsOnPumpThread => true;
        public void SendManagerRequest(uint opcode) { }
        public void ScheduleManage() { }
        public void Init(IntPtr managerProxy, IntPtr display) { }
        public void SetSeat(IntPtr seat) { }
        public void Reset() { }
        public void SetPumpThread(int managedThreadId) { }
        public void DrainPumpQueue() { }
        public void Post(Action action) => action();
        public void SuppressPointerConstraints(bool pressed) { }
    }

    private sealed class NullLayerShellTeardownService : ILayerShellTeardownService
    {
        public void TeardownSeat(IntPtr seat) { }
        public void TeardownOutput(IntPtr output) { }
        public void TeardownAll() { }
    }
}
