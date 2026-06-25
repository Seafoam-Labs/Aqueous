using System;
using Aqueous.Features.Focus;
using Xunit;

namespace Aqueous.Tests.Features.Focus;

public sealed class FocusHistoryStoreTests
{
    [Fact]
    public void Record_FirstWindowForWorkspace_DoesNotThrow()
    {
        var store = new FocusHistoryStore();
        var workspace = new IntPtr(0x1000);
        var window = new IntPtr(0x2000);

        store.Record(workspace, window);

        Assert.Equal(window, store.PickWindow(workspace, _ => true));
    }

    [Fact]
    public void PickWindow_ReturnsMostRecentlyFocusedValidWindow()
    {
        var store = new FocusHistoryStore();
        var workspace = new IntPtr(0x1000);
        var first = new IntPtr(0x2000);
        var second = new IntPtr(0x3000);

        store.Record(workspace, first);
        store.Record(workspace, second);

        Assert.Equal(second, store.PickWindow(workspace, _ => true));
    }

    [Fact]
    public void Record_ExistingWindow_MovesWindowToFront()
    {
        var store = new FocusHistoryStore();
        var workspace = new IntPtr(0x1000);
        var first = new IntPtr(0x2000);
        var second = new IntPtr(0x3000);

        store.Record(workspace, first);
        store.Record(workspace, second);
        store.Record(workspace, first);

        Assert.Equal(first, store.PickWindow(workspace, _ => true));
    }

    [Fact]
    public void PickWindow_PrunesInvalidEntries()
    {
        var store = new FocusHistoryStore();
        var workspace = new IntPtr(0x1000);
        var stale = new IntPtr(0x2000);
        var valid = new IntPtr(0x3000);

        store.Record(workspace, valid);
        store.Record(workspace, stale);

        Assert.Equal(valid, store.PickWindow(workspace, window => window != stale));
        Assert.Equal(valid, store.PickWindow(workspace, _ => true));
    }

    [Fact]
    public void Record_ZeroWorkspace_IgnoresWindow()
    {
        var store = new FocusHistoryStore();
        var window = new IntPtr(0x2000);

        store.Record(IntPtr.Zero, window);

        Assert.Equal(IntPtr.Zero, store.PickWindow(IntPtr.Zero, _ => true));
    }
}
