using System;
using Aqueous.Features.Compositor.River.Dispatch;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Dispatch;

/// <summary>
/// Unit tests for Stage 0 of the <c>RiverWindowManagerClient</c>
/// decomposition: <see cref="ProxyInterfaceMap"/>.
///
/// These tests cover only the helper's semantics. The full Stage 0
/// "every proxy ProxyDispatcher.Dispatch can route has a non-empty
/// entry in the map" sanity check requires a live (or recorded)
/// Wayland session and lives outside the unit-test layer.
/// </summary>
public sealed class ProxyInterfaceMapTests
{
    [Fact]
    public void Track_records_interface_name_for_proxy()
    {
        var map = new ProxyInterfaceMap();
        var p = new IntPtr(0xDEAD);

        Assert.True(map.Track(p, "wl_seat"));

        Assert.Equal(1, map.Count);
        Assert.Equal("wl_seat", map.TryGet(p));
    }

    [Fact]
    public void Track_zero_pointer_is_silent_noop()
    {
        var map = new ProxyInterfaceMap();
        Assert.False(map.Track(IntPtr.Zero, "wl_seat"));
        Assert.Equal(0, map.Count);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    public void Track_null_or_empty_name_is_silent_noop(string? name)
    {
        var map = new ProxyInterfaceMap();
        Assert.False(map.Track(new IntPtr(0xABCD), name));
        Assert.Equal(0, map.Count);
    }

    [Fact]
    public void Track_is_idempotent_for_same_proxy()
    {
        var map = new ProxyInterfaceMap();
        var p = new IntPtr(0xCAFE);

        Assert.True(map.Track(p, "wl_output"));
        Assert.False(map.Track(p, "wl_output"));

        Assert.Equal(1, map.Count);
        Assert.Equal("wl_output", map.TryGet(p));
    }

    [Fact]
    public void Track_does_not_overwrite_existing_mapping_with_different_name()
    {
        var map = new ProxyInterfaceMap();
        var p = new IntPtr(0xBEEF);

        Assert.True(map.Track(p, "wl_seat"));
        Assert.False(map.Track(p, "wl_output"));

        Assert.Equal("wl_seat", map.TryGet(p));
        Assert.Equal(1, map.Count);
    }

    [Fact]
    public void TryGet_returns_null_for_unknown_proxy()
    {
        var map = new ProxyInterfaceMap();
        Assert.Null(map.TryGet(new IntPtr(0x1234)));
    }

    [Fact]
    public void Untrack_removes_existing_mapping()
    {
        var map = new ProxyInterfaceMap();
        var p = new IntPtr(0x5678);
        map.Track(p, "wl_shm");

        Assert.True(map.Untrack(p));
        Assert.False(map.Untrack(p));
        Assert.Null(map.TryGet(p));
        Assert.Equal(0, map.Count);
    }

    [Fact]
    public void Multiple_proxies_can_share_an_interface_name()
    {
        var map = new ProxyInterfaceMap();
        map.Track(new IntPtr(1), "river_pointer_binding_v1");
        map.Track(new IntPtr(2), "river_pointer_binding_v1");
        map.Track(new IntPtr(3), "river_xkb_binding_v1");

        Assert.Equal(3, map.Count);
        Assert.Equal("river_pointer_binding_v1", map.TryGet(new IntPtr(1)));
        Assert.Equal("river_pointer_binding_v1", map.TryGet(new IntPtr(2)));
        Assert.Equal("river_xkb_binding_v1", map.TryGet(new IntPtr(3)));
    }
}
