using System;
using System.Collections.Generic;
using Aqueous.Features.Workspaces;
using Xunit;

namespace Aqueous.Tests.Features.Workspaces;

/// <summary>
/// Logic tests for <see cref="WorkspaceController"/> driven against a real <see cref="WorkspaceStore"/>
/// and a recording <see cref="WorkspaceController.IWorkspaceHost"/>. No Wayland is involved: the
/// host records which workspace handle would be activated / moved to.
/// </summary>
public class WorkspaceControllerTests
{
    private sealed class RecordingHost : WorkspaceController.IWorkspaceHost
    {
        public WorkspaceStore Store { get; } = new();
        public List<IntPtr> Activated { get; } = new();
        public List<IntPtr> Moved { get; } = new();
        public bool HasFocus { get; set; } = true;
        public int AfterChangeCount { get; private set; }

        public void ActivateWorkspace(IntPtr workspace)
        {
            Activated.Add(workspace);
            // Mirror the compositor's exclusive activation so subsequent resolution sees the change.
            if (Store.TryGetWorkspace(workspace, out var w) && w.Group != IntPtr.Zero &&
                Store.GetCurrentGroup() is { } g)
            {
                foreach (var ws in g.Workspaces)
                {
                    Store.SetState(ws, ws == workspace, false);
                }
            }
        }

        public bool MoveFocusedToWorkspace(IntPtr workspace)
        {
            if (!HasFocus) return false;
            Moved.Add(workspace);
            return true;
        }

        public void AfterChange() => AfterChangeCount++;
    }

    private static (RecordingHost host, IntPtr[] ws) Seed(int count)
    {
        var host = new RecordingHost();
        IntPtr group = 1000;
        host.Store.AddGroup(group);
        var ws = new IntPtr[count];
        for (int i = 0; i < count; i++)
        {
            ws[i] = 2000 + i;
            host.Store.EnterGroup(group, ws[i]);
        }

        // First workspace active.
        host.Store.SetState(ws[0], active: true, urgent: false);
        host.Store.CurrentGroup = group;
        return (host, ws);
    }

    [Fact]
    public void FocusWorkspaceByIndex_ActivatesCorrectHandle()
    {
        var (host, ws) = Seed(3);
        var c = new WorkspaceController(host);

        Assert.True(c.FocusWorkspaceByIndex(2));
        Assert.Equal(ws[1], Assert.Single(host.Activated));
        Assert.Equal(1, host.AfterChangeCount);
    }

    [Fact]
    public void FocusWorkspaceByIndex_OutOfRange_ReturnsFalse()
    {
        var (host, _) = Seed(2);
        var c = new WorkspaceController(host);

        Assert.False(c.FocusWorkspaceByIndex(5));
        Assert.Empty(host.Activated);
    }

    [Fact]
    public void FocusWorkspaceDownThenUp_MovesRelativeToActive()
    {
        var (host, ws) = Seed(3);
        long clock = 0;
        var c = new WorkspaceController(host, () => clock);

        Assert.True(c.FocusWorkspaceDown());
        Assert.Equal(ws[1], host.Activated[^1]);

        clock += 1000; // past the debounce window so the second switch dispatches immediately
        Assert.True(c.FocusWorkspaceUp());
        Assert.Equal(ws[0], host.Activated[^1]);
    }

    [Fact]
    public void FocusWorkspaceUp_AtTop_ReturnsFalse()
    {
        var (host, _) = Seed(3);
        var c = new WorkspaceController(host);

        Assert.False(c.FocusWorkspaceUp());
        Assert.Empty(host.Activated);
    }

    [Fact]
    public void FocusPreviousWorkspace_ReturnsToPriorActive()
    {
        var (host, ws) = Seed(3);
        long clock = 0;
        var c = new WorkspaceController(host, () => clock);

        Assert.True(c.FocusWorkspaceByIndex(3)); // switch to ws[2]; previous = ws[0]
        clock += 1000;
        Assert.True(c.FocusPreviousWorkspace());
        Assert.Equal(ws[0], host.Activated[^1]);
    }

    [Fact]
    public void RapidSwitch_CommitsLeadingImmediately_CoalescesLatestUntilFlush()
    {
        var (host, ws) = Seed(4);
        long clock = 0;
        var c = new WorkspaceController(host, () => clock);

        Assert.True(c.FocusWorkspaceByIndex(2)); // leading edge -> ws[1] dispatched immediately
        Assert.True(c.FocusWorkspaceByIndex(3)); // within window -> coalesced
        Assert.True(c.FocusWorkspaceByIndex(4)); // within window -> coalesced; latest = ws[3]

        // Only the leading switch reached the host; the burst is suppressed.
        Assert.Equal(ws[1], Assert.Single(host.Activated));

        // Still inside the window: flushing is a no-op.
        c.FlushPending();
        Assert.Single(host.Activated);

        // Past the window: the latest coalesced target is dispatched.
        clock += 1000;
        c.FlushPending();
        Assert.Equal(2, host.Activated.Count);
        Assert.Equal(ws[3], host.Activated[^1]);
    }

    [Fact]
    public void RapidSwitch_EndingOnLeadingTarget_FlushIsNoOp()
    {
        var (host, ws) = Seed(3);
        long clock = 0;
        var c = new WorkspaceController(host, () => clock);

        Assert.True(c.FocusWorkspaceByIndex(2)); // leading -> ws[1]
        Assert.True(c.FocusWorkspaceByIndex(1)); // coalesced -> ws[0]
        Assert.True(c.FocusWorkspaceByIndex(2)); // coalesced -> ws[1] (== last committed)

        clock += 1000;
        c.FlushPending();

        // The pending target equals the already-active workspace, so nothing is re-dispatched.
        Assert.Equal(ws[1], Assert.Single(host.Activated));
    }

    [Fact]
    public void FlushPending_NothingPending_DoesNothing()
    {
        var (host, _) = Seed(3);
        var c = new WorkspaceController(host);

        c.FlushPending();
        Assert.Empty(host.Activated);
    }

    [Fact]
    public void MoveFocusedToWorkspaceByIndex_RecordsMove()
    {
        var (host, ws) = Seed(3);
        var c = new WorkspaceController(host);

        Assert.True(c.MoveFocusedToWorkspaceByIndex(3));
        Assert.Equal(ws[2], Assert.Single(host.Moved));
    }

    [Fact]
    public void MoveFocusedToWorkspace_NoFocus_ReturnsFalse()
    {
        var (host, _) = Seed(3);
        host.HasFocus = false;
        var c = new WorkspaceController(host);

        Assert.False(c.MoveFocusedToWorkspaceByIndex(2));
        Assert.Empty(host.Moved);
    }

    [Fact]
    public void FocusPreviousWorkspace_WhenPreviousReaped_DoesNotDriveDeadHandle()
    {
        var (host, ws) = Seed(3);
        var c = new WorkspaceController(host);

        Assert.True(c.FocusWorkspaceByIndex(3)); // switch to ws[2]; previous = ws[0]
        host.Activated.Clear();

        // The previously-active workspace is reaped by the compositor (removed event).
        host.Store.RemoveWorkspace(ws[0]);

        // Must not activate a workspace that no longer exists.
        Assert.False(c.FocusPreviousWorkspace());
        Assert.Empty(host.Activated);
    }

    [Fact]
    public void MoveFocusedToWorkspace_WhenTargetReaped_ReturnsFalse()
    {
        var (host, ws) = Seed(3);
        var c = new WorkspaceController(host);

        // Reaping ws[2] removes it from the group, so index 3 no longer resolves; but even a
        // directly-resolved dead handle must be rejected by the guard.
        host.Store.RemoveWorkspace(ws[2]);

        Assert.False(c.MoveFocusedToWorkspaceByIndex(3));
        Assert.Empty(host.Moved);
    }

    [Fact]
    public void MoveWorkspaceUp_NotSupported_ReturnsFalse()
    {
        var (host, _) = Seed(3);
        var c = new WorkspaceController(host);

        Assert.False(c.MoveWorkspaceUp());
        Assert.False(c.MoveWorkspaceDown());
    }
}
