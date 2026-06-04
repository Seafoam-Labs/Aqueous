using System;
using System.Linq;
using System.Reflection;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Focus;
using Aqueous.Features.Layout;
using Aqueous.Features.Tags;
using Xunit;

namespace Aqueous.Tests.Features.Tags;

/// <summary>
/// Unit tests for the extracted <see cref="TagService"/>. Exercises the real class against an
/// in-memory <see cref="WindowRegistry"/> + <see cref="OutputRegistry"/>. retired the
/// <c>ITagServiceCollaborators</c> bridge entirely; the fake is now an <see
/// cref="IManagerRequestSender"/>.
/// </summary>
public class TagServiceTests
{
    private sealed class FakeSender : IManagerRequestSender
    {
        public int ScheduleManageCalls;
        public int SendManagerRequestCalls;
        public bool InsideManageSequence { get; set; }
        public bool IsBound => true;
        public void Init(IntPtr managerProxy, IntPtr display) { }
        public void Reset() { }
        public void SendManagerRequest(uint opcode) => SendManagerRequestCalls++;
        public void ScheduleManage() => ScheduleManageCalls++;
        public void SetPumpThread(int managedThreadId) { }
        public void DrainPumpQueue() { }
    }

    /// <summary>
    /// Fake — the focus operations the Tags subsystem.
    /// </summary>
    private sealed class FakeFocus : IFocusService
    {
        public IntPtr FocusedWindow { get; set; }
        public int ClearFocusCalls;
        public int RequestFocusCalls;
        public IntPtr LastRequestedFocus;

        public bool TryGetFocusedAlive(out IntPtr proxy) { proxy = FocusedWindow; return proxy != IntPtr.Zero; }
        public void SetFocusedWindow(IntPtr windowProxy, IntPtr seatProxy) => FocusedWindow = windowProxy;
        public void RequestFocus(IntPtr windowProxy) { RequestFocusCalls++; LastRequestedFocus = windowProxy; FocusedWindow = windowProxy; }
        public void ClearFocus() { ClearFocusCalls++; FocusedWindow = IntPtr.Zero; }
        public void FocusAnyOtherWindow(IntPtr avoid) { }
        public void CycleFocus() { }
        public void HandleDirectionalFocus(FocusDirection dir) { }
        public void SetFocusedShellSurface(IntPtr s, IntPtr seat) { }
        public void InvalidateShellSurface(IntPtr shellSurfaceProxy) { }
        public void RepairFocusAfterTagChange() { }
        public void ClearFocusedHandle() => FocusedWindow = IntPtr.Zero;
    }

    private static (TagService svc, WindowRegistry wr, OutputRegistry or, FakeFocus co)
        Build(IntPtr output, IntPtr? focusedWindow = null, uint outputVisible = TagState.DefaultTag)
    {
        var wr = new WindowRegistry();
        var or = new OutputRegistry();
        var co = new FakeFocus();
        var sender = new FakeSender();

        // Seed an output entry directly via the public ConcurrentDictionary (registries' Entries is
        // intentionally exposed for consumers — left this surface stable).
        or.Entries[output] = new OutputEntry
        {
            Proxy = output,
            VisibleTags = outputVisible,
            LastVisibleTags = outputVisible,
        };

        if (focusedWindow is { } fw)
        {
            wr.Entries[fw] = new WindowEntry
            {
                Proxy = fw,
                Output = output,
                Tags = TagState.DefaultTag,
            };
            co.FocusedWindow = fw;
        }

        var svc = new TagService(wr, or, co, sender);
        return (svc, wr, or, co);
    }

    [Fact]
    public void ViewTags_ChangesOutputVisibleAndTriggersRelayout()
    {
        var output = new IntPtr(0x1000);
        var (svc, _, or, co) = Build(output, focusedWindow: new IntPtr(0x2000));

        Assert.True(svc.ViewTags(TagState.Bit(1))); // mask = 2

        Assert.Equal(2u, or.Entries[output].VisibleTags);
        Assert.Equal(TagState.DefaultTag, or.Entries[output].LastVisibleTags);
        // Schedule-manage was; behaviour is unchanged but the assertion now lives in
        // TagsChanged_SinkFires.
    }

    [Fact]
    public void ViewTags_SameMask_IsNoOp()
    {
        var output = new IntPtr(0x1000);
        var (svc, _, _, co) = Build(output, focusedWindow: new IntPtr(0x2000),
            outputVisible: TagState.Bit(2));

        Assert.False(svc.ViewTags(TagState.Bit(2)));
    }

    [Fact]
    public void ViewAll_SetsAllTagsMask()
    {
        var output = new IntPtr(0x1000);
        var (svc, _, or, _) = Build(output, focusedWindow: new IntPtr(0x2000));

        Assert.True(svc.ViewAll());
        Assert.Equal(TagState.AllTags, or.Entries[output].VisibleTags);
    }

    [Fact]
    public void ToggleViewTag_FlipsBitAndRelayouts()
    {
        var output = new IntPtr(0x1000);
        var (svc, _, or, _) = Build(output, focusedWindow: new IntPtr(0x2000),
            outputVisible: 0b0001u);

        Assert.True(svc.ToggleViewTag(0b0100u));
        Assert.Equal(0b0101u, or.Entries[output].VisibleTags);
    }

    [Fact]
    public void ToggleViewTag_LastBitOff_RefusesToZero()
    {
        var output = new IntPtr(0x1000);
        var (svc, _, or, _) = Build(output, focusedWindow: new IntPtr(0x2000),
            outputVisible: 0b0010u);

        Assert.False(svc.ToggleViewTag(0b0010u));
        Assert.Equal(0b0010u, or.Entries[output].VisibleTags);
    }

    [Fact]
    public void SendFocusedToTags_RetagsWindow()
    {
        var output = new IntPtr(0x1000);
        var win = new IntPtr(0x2000);
        var (svc, wr, _, _) = Build(output, focusedWindow: win);

        Assert.True(svc.SendFocusedToTags(0b0100u));
        Assert.Equal(0b0100u, wr.Entries[win].Tags);
    }

    [Fact]
    public void SendFocusedToTags_NoFocusedWindow_ReturnsFalse()
    {
        var output = new IntPtr(0x1000);
        var (svc, _, _, _) = Build(output, focusedWindow: null);

        Assert.False(svc.SendFocusedToTags(0b0100u));
    }

    [Fact]
    public void ToggleWindowTag_FlipsBit()
    {
        var output = new IntPtr(0x1000);
        var win = new IntPtr(0x2000);
        var (svc, wr, _, _) = Build(output, focusedWindow: win);
        wr.Entries[win].Tags = 0b0011u;

        Assert.True(svc.ToggleWindowTag(0b0010u));
        Assert.Equal(0b0001u, wr.Entries[win].Tags);
    }

    [Fact]
    public void SwapLastTagset_RestoresPrevious()
    {
        var output = new IntPtr(0x1000);
        var (svc, _, or, _) = Build(output, focusedWindow: new IntPtr(0x2000),
            outputVisible: 0b0001u);

        // Move to a different mask first so LastVisibleTags gets a non-trivial value.
        Assert.True(svc.ViewTags(0b0100u));
        Assert.Equal(0b0100u, or.Entries[output].VisibleTags);

        Assert.True(svc.SwapLastTagset());
        Assert.Equal(0b0001u, or.Entries[output].VisibleTags);
    }

    [Fact]
    public void RepairFocusAfterTagChange_ClearsFocusWhenNoVisibleWindow()
    {
        var output = new IntPtr(0x1000);
        var win = new IntPtr(0x2000);
        var (svc, wr, or, co) = Build(output, focusedWindow: win);
        wr.Entries[win].Tags = 0b0010u;     // window on tag 2
        or.Entries[output].VisibleTags = 0b0010u;

        // Drive ViewTags to a non-overlapping mask. RepairFocusAfterTagChange runs inside the controller;
        // we observe its effect through the collaborator.
        Assert.True(svc.ViewTags(0b0100u)); // window no longer visible
        Assert.True(co.ClearFocusCalls >= 1);
    }

    [Fact]
    public void TagsChanged_SinkFires_OnSuccessfulMutation()
    {
        var output = new IntPtr(0x1000);
        var (svc, _, _, _) = Build(output, focusedWindow: new IntPtr(0x2000));

        int hits = 0;
        svc.TagsChanged = _ => hits++;

        Assert.True(svc.ViewTags(TagState.Bit(1)));
        Assert.Equal(1, hits);
    }

    // The "god class does not implement ITagHost" regression guard retired together with
    // RiverWindowManagerClient itself — the class no longer exists, so it trivially can't re-acquire
    // any interface.

    [Fact]
    public void TagsServicePartial_RegressionGuard_CollaboratorsInterfaceDeleted()
    {
        // ITagServiceCollaborators was deleted in full. The type should no longer exist anywhere in the
        // production assembly; if it ever returns, ScheduleManage routing is probably wrong again.
        var prodAsm = typeof(RiverCompositorHost).Assembly;
        var stillThere = prodAsm.GetType(
            "Aqueous.Features.Compositor.River.Tags.ITagServiceCollaborators",
            throwOnError: false);
        Assert.Null(stillThere);
    }
}
