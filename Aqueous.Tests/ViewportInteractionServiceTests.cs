using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Focus;
using Aqueous.Features.Layout;
using Aqueous.Features.Tags;
using Aqueous.Features.Workspaces;
using Xunit;

namespace Aqueous.Tests;

public class ViewportInteractionServiceTests
{
    [Fact]
    public void ScrollViewport_DoesNotThrottle_NonScrollingLayout()
    {
        var fixture = CreateFixture("tile", "500");

        fixture.Service.ScrollViewport(1);
        fixture.Service.ScrollViewport(1);

        Assert.Equal(2, fixture.Requests.ScheduleManageCalls);
    }

    [Fact]
    public void ScrollViewport_DoesNotThrottle_ScrollingWithoutThrottle()
    {
        var fixture = CreateFixture("scrolling", null);

        fixture.Service.ScrollViewport(1);
        fixture.Service.ScrollViewport(1);

        Assert.Equal(2, fixture.Requests.ScheduleManageCalls);
    }

    [Fact]
    public void ScrollViewport_ThrottlesRepeatedScrollingNavigation()
    {
        var fixture = CreateFixture("scrolling", "500");

        fixture.Service.ScrollViewport(1);
        fixture.Service.ScrollViewport(1);

        Assert.Equal(1, fixture.Requests.ScheduleManageCalls);
    }

    [Fact]
    public async Task ScrollViewport_AllowsScrollingNavigation_AfterThrottleExpires()
    {
        var fixture = CreateFixture("scrolling", "40");

        fixture.Service.ScrollViewport(1);
        await Task.Delay(90);
        fixture.Service.ScrollViewport(1);

        Assert.Equal(2, fixture.Requests.ScheduleManageCalls);
    }

    private static Fixture CreateFixture(string layoutId, string? throttleMs)
    {
        var extra = new Dictionary<string, string>();
        if (throttleMs != null)
        {
            extra["scroll_navigation_throttle_ms"] = throttleMs;
        }

        var config = new LayoutConfig
        {
            DefaultLayout = layoutId,
            PerLayoutOpts = new Dictionary<string, LayoutOptions>
            {
                ["scrolling"] = LayoutOptions.Default with { Extra = extra },
            },
        };
        var controller = new LayoutController(new LayoutRegistry(), config);
        var focused = new FocusedWindowTracker { Current = new IntPtr(10) };
        var windows = new WindowRegistry();
        var output = new IntPtr(20);
        var window = windows.Track(focused.Current);
        window.Output = output;
        window.Tags = 1;
        var outputs = new OutputRegistry();
        outputs.Track(output, 1);
        var proposer = new NullLayoutProposer();
        var requests = new RecordingManagerRequestSender();
        var workspaces = new WorkspaceStore();
        var group = new IntPtr(30);
        var workspace = new IntPtr(40);
        workspaces.EnterGroup(group, workspace);
        workspaces.SetGroupOutput(group, output);
        workspaces.SetState(workspace, true, false);
        var service = new ViewportInteractionService(controller, focused, windows, outputs, proposer, requests, workspaces);
        return new Fixture(service, requests);
    }

    private sealed record Fixture(ViewportInteractionService Service, RecordingManagerRequestSender Requests);

    private sealed class NullLayoutProposer : ILayoutProposer
    {
        public void ProposeForArea(IntPtr output, string? outputName, Rect usableArea) { }
        public void ProposeForArea(IntPtr output, string? outputName, Rect outputRect, Rect usableArea) { }
        public bool IsFloatLayoutActive() => false;
        public bool IsFloatLayoutActive(IntPtr output) => false;
        public IReadOnlyList<WindowEntryView> BuildSnapshotFor(IntPtr output) => Array.Empty<WindowEntryView>();
        public string? ResolveOutputName(IntPtr output) => null;
        public IntPtr? LayoutFocusNeighbor(IntPtr output, string? outputName, IntPtr current, FocusDirection dir, IReadOnlyList<WindowEntryView> snapshot, uint visibleTags) => null;
    }

    private sealed class RecordingManagerRequestSender : IManagerRequestSender
    {
        public int ScheduleManageCalls { get; private set; }
        public bool InsideManageSequence { get; set; }
        public bool IsBound => true;
        public bool IsOnPumpThread => true;
        public void SendManagerRequest(uint opcode) { }
        public void ScheduleManage() => ScheduleManageCalls++;
        public void Init(IntPtr managerProxy, IntPtr display) { }
        public void SetSeat(IntPtr seat) { }
        public void Reset() { }
        public void SetPumpThread(int managedThreadId) { }
        public void DrainPumpQueue() { }
        public void Post(Action action) => action();
        public void SuppressPointerConstraints(bool pressed) { }
    }
}
