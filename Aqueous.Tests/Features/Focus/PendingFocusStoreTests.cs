using System;
using Aqueous.Features.Focus;
using Xunit;

namespace Aqueous.Tests.Features.Focus;

/// <summary>
/// Behavioural pins for <see cref="PendingFocusStore"/> shell-surface liveness tracking. These
/// guard the fix for the "running sherlock occasionally crashes aqueous" use-after-free: the
/// manage-cycle drain only marshals <c>focus_shell_surface</c> when the proxy is still known live,
/// so a layer-shell client that closes between <c>shell_surface_interaction</c> and the drain can no
/// longer cause a marshal on a freed proxy.
/// </summary>
public sealed class PendingFocusStoreTests
{
    private static readonly IntPtr Seat = (IntPtr)0x1000;
    private static readonly IntPtr Shell = (IntPtr)0x2000;
    private static readonly IntPtr Window = (IntPtr)0x3000;

    [Fact]
    public void SetShellSurface_MarksProxyLive()
    {
        var store = new PendingFocusStore();
        store.SetShellSurface(Shell, Seat);

        Assert.Equal(Shell, store.ShellSurface);
        Assert.Equal(Seat, store.Seat);
        Assert.Equal(IntPtr.Zero, store.Window);
        Assert.True(store.IsShellSurfaceLive(Shell));
    }

    [Fact]
    public void ForgetShellSurface_InvalidatesLiveness()
    {
        var store = new PendingFocusStore();
        store.SetShellSurface(Shell, Seat);

        store.ForgetShellSurface(Shell);

        Assert.False(store.IsShellSurfaceLive(Shell));
    }

    [Fact]
    public void SetWindow_SupersedingShellSurface_DropsLiveness()
    {
        var store = new PendingFocusStore();
        store.SetShellSurface(Shell, Seat);

        store.SetWindow(Window, Seat);

        Assert.Equal(IntPtr.Zero, store.ShellSurface);
        Assert.False(store.IsShellSurfaceLive(Shell));
    }

    [Fact]
    public void Clear_DropsShellSurfaceLiveness()
    {
        var store = new PendingFocusStore();
        store.SetShellSurface(Shell, Seat);

        store.Clear();

        Assert.Equal(IntPtr.Zero, store.ShellSurface);
        Assert.Equal(IntPtr.Zero, store.Seat);
        Assert.False(store.IsShellSurfaceLive(Shell));
    }

    [Fact]
    public void IsShellSurfaceLive_FalseForUntrackedOrZero()
    {
        var store = new PendingFocusStore();

        Assert.False(store.IsShellSurfaceLive(Shell));
        Assert.False(store.IsShellSurfaceLive(IntPtr.Zero));
    }
}
