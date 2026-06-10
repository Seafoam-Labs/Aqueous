using System;
using Aqueous.Features.Workspaces;
using Xunit;

namespace Aqueous.Tests.Features.Workspaces;

/// <summary>
/// Unit coverage for <see cref="WorkspaceStore.IsHiddenByWorkspace"/> — the oracle the layout
/// proposer consults to drop off-workspace windows from the tiled snapshot (the fix for the
/// half-size symptom). The proposer itself is gated on manual River smoke, so the visibility
/// contract is pinned here at the store level.
/// </summary>
public sealed class WorkspaceStoreTests
{
    private static WorkspaceStore Seed(out IntPtr active, out IntPtr inactive)
    {
        var store = new WorkspaceStore();
        IntPtr group = 1000;
        active = 2000;
        inactive = 2001;
        store.AddGroup(group);
        store.EnterGroup(group, active);
        store.EnterGroup(group, inactive);
        store.SetState(active, active: true, urgent: false);
        store.SetState(inactive, active: false, urgent: false);
        return store;
    }

    [Fact]
    public void Unassigned_Zero_IsNeverHidden()
    {
        var store = Seed(out _, out _);
        Assert.False(store.IsHiddenByWorkspace(IntPtr.Zero));
    }

    [Fact]
    public void ActiveWorkspace_IsVisible()
    {
        var store = Seed(out var active, out _);
        Assert.False(store.IsHiddenByWorkspace(active));
    }

    [Fact]
    public void InactiveWorkspace_IsHidden()
    {
        var store = Seed(out _, out var inactive);
        Assert.True(store.IsHiddenByWorkspace(inactive));
    }

    [Fact]
    public void ReapedWorkspace_IsTreatedVisible()
    {
        var store = Seed(out _, out var inactive);
        // Compositor reaps the (inactive) workspace; a window still pointing at the now-untracked
        // handle must not be stranded off-screen — IsHiddenByWorkspace returns false.
        store.RemoveWorkspace(inactive);
        Assert.False(store.IsHiddenByWorkspace(inactive));
    }

    [Fact]
    public void SwitchingActive_FlipsVisibility()
    {
        var store = Seed(out var first, out var second);
        // Mirror an exclusive activation: second becomes active, first goes inactive.
        store.SetState(first, active: false, urgent: false);
        store.SetState(second, active: true, urgent: false);

        Assert.True(store.IsHiddenByWorkspace(first));
        Assert.False(store.IsHiddenByWorkspace(second));
    }
}
