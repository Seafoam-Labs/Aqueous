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
        var c = new WorkspaceController(host);

        Assert.True(c.FocusWorkspaceDown());
        Assert.Equal(ws[1], host.Activated[^1]);

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
        var c = new WorkspaceController(host);

        Assert.True(c.FocusWorkspaceByIndex(3)); // switch to ws[2]; previous = ws[0]
        Assert.True(c.FocusPreviousWorkspace());
        Assert.Equal(ws[0], host.Activated[^1]);
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
    public void MoveWorkspaceUp_NotSupported_ReturnsFalse()
    {
        var (host, _) = Seed(3);
        var c = new WorkspaceController(host);

        Assert.False(c.MoveWorkspaceUp());
        Assert.False(c.MoveWorkspaceDown());
    }
}
