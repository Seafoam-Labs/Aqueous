using System;
using System.Collections.Concurrent;
using System.Reflection;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.State;
using Xunit;

namespace Aqueous.Tests;

/// <summary>
/// Tests for the host-side <c>RiverWindowStateHost.InvalidateFloatRect</c>
/// adapter on <see cref="RiverWindowManagerClient"/>. The adapter is the
/// only code path that flips <c>WindowEntry.HasFloatRect</c> back to
/// <c>false</c> and re-arms the position/size diff-gates the
/// <c>LayoutProposer</c> floating loop guards on; if it silently no-ops
/// (as it did when the <c>TryGetValue</c> guard shipped inverted) the
/// maximize-button restore round-trip is broken.
///
/// Both <see cref="RiverWindowManagerClient"/> (private ctor) and the
/// nested <c>RiverWindowStateHost</c> (private class) are reachable only
/// via reflection. <c>InternalsVisibleTo("Aqueous.Tests")</c> covers
/// member visibility for the rest of the surface (<c>WindowEntry</c>,
/// <c>_windows</c>).
/// </summary>
public class InvalidateFloatRectTests
{
    private sealed class Harness
    {
        public required RiverWindowManagerClient Client;
        public required IWindowStateHost Host;
        public required ConcurrentDictionary<IntPtr, WindowEntry> Windows;
    }

    private static Harness Build()
    {
        var ctor = typeof(RiverWindowManagerClient).GetConstructor(
            BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public,
            binder: null, types: Type.EmptyTypes, modifiers: null);
        Assert.NotNull(ctor);
        var client = (RiverWindowManagerClient)ctor!.Invoke(null);

        var stateHostField = typeof(RiverWindowManagerClient).GetField(
            "_stateHost", BindingFlags.Instance | BindingFlags.NonPublic);
        Assert.NotNull(stateHostField);
        var host = (IWindowStateHost)stateHostField!.GetValue(client)!;

        var windowsField = typeof(RiverWindowManagerClient).GetField(
            "_windows", BindingFlags.Instance | BindingFlags.NonPublic);
        Assert.NotNull(windowsField);
        var windows = (ConcurrentDictionary<IntPtr, WindowEntry>)windowsField!.GetValue(client)!;

        return new Harness { Client = client, Host = host, Windows = windows };
    }

    [Fact]
    public void InvalidateFloatRect_ResetsAllFourGates()
    {
        var h = Build();
        var handle = new IntPtr(0xDEAD);
        var entry = new WindowEntry
        {
            HasFloatRect = true,
            LastPosX = 100,
            LastPosY = 200,
            LastHintW = 800,
            LastHintH = 600,
        };
        h.Windows[handle] = entry;

        h.Host.InvalidateFloatRect(new WindowProxy(handle));

        Assert.False(entry.HasFloatRect);
        Assert.NotEqual(100, entry.LastPosX);
        Assert.NotEqual(200, entry.LastPosY);
        Assert.NotEqual(800, entry.LastHintW);
        Assert.NotEqual(600, entry.LastHintH);
        // The entry itself must not have been removed.
        Assert.True(h.Windows.ContainsKey(handle));
    }

    [Fact]
    public void InvalidateFloatRect_SentinelsCannotMatchRealValues()
    {
        // The reset values must compare not-equal to any plausible real
        // position/size so the LayoutProposer diff-gates fire on the next
        // cycle. Real values are non-negative for sizes; positions can be
        // negative on multi-output setups but never int.MinValue.
        var h = Build();
        var handle = new IntPtr(0xC0DE);
        var entry = new WindowEntry { HasFloatRect = true };
        h.Windows[handle] = entry;

        h.Host.InvalidateFloatRect(new WindowProxy(handle));

        // Position sentinels: must be < any real screen coordinate.
        Assert.True(entry.LastPosX <= -1_000_000);
        Assert.True(entry.LastPosY <= -1_000_000);
        // Size sentinels: must be != any positive width/height. Either
        // 0 or int.MinValue satisfies the diff-gate (`pw != LastHintW`).
        Assert.True(entry.LastHintW <= 0);
        Assert.True(entry.LastHintH <= 0);
    }

    [Fact]
    public void InvalidateFloatRect_UnknownHandle_IsNoOp()
    {
        var h = Build();
        var unknown = new IntPtr(0xBADD);

        // Must not throw, must not insert a phantom entry.
        h.Host.InvalidateFloatRect(new WindowProxy(unknown));

        Assert.False(h.Windows.ContainsKey(unknown));
    }

    [Fact]
    public void InvalidateFloatRect_ZeroProxy_IsNoOp()
    {
        var h = Build();
        // Zero handle is the documented "no window" sentinel; the host
        // must tolerate it without throwing or inserting an entry.
        h.Host.InvalidateFloatRect(WindowProxy.Zero);
        Assert.False(h.Windows.ContainsKey(IntPtr.Zero));
    }

    [Fact]
    public void InvalidateFloatRect_DoesNotTouchOtherEntries()
    {
        var h = Build();
        var target = new IntPtr(0xAA);
        var bystander = new IntPtr(0xBB);
        h.Windows[target] = new WindowEntry
        {
            HasFloatRect = true, LastPosX = 1, LastPosY = 2,
            LastHintW = 3, LastHintH = 4,
        };
        var keep = new WindowEntry
        {
            HasFloatRect = true, LastPosX = 11, LastPosY = 22,
            LastHintW = 33, LastHintH = 44,
        };
        h.Windows[bystander] = keep;

        h.Host.InvalidateFloatRect(new WindowProxy(target));

        Assert.True(keep.HasFloatRect);
        Assert.Equal(11, keep.LastPosX);
        Assert.Equal(22, keep.LastPosY);
        Assert.Equal(33, keep.LastHintW);
        Assert.Equal(44, keep.LastHintH);
    }

    [Fact]
    public void SetToplevelMaximizedState_TogglesXdgFlagAndRearmsSizeGate()
    {
        // Mirror of the Chromium / Alacritty fix: the host hook must
        // flip the per-entry XdgMaximized flag (consumed by any future
        // xdg_toplevel.configure marshal) and re-arm the size diff-gate
        // so a fresh propose_dimensions goes out together with the new
        // state array even if the size happens to be unchanged.
        var h = Build();
        var handle = new IntPtr(0xBEEF);
        var entry = new WindowEntry
        {
            XdgMaximized = false,
            LastHintW = 1024,
            LastHintH = 768,
        };
        h.Windows[handle] = entry;

        h.Host.SetToplevelMaximizedState(new WindowProxy(handle), maximized: true);
        Assert.True(entry.XdgMaximized);
        Assert.NotEqual(1024, entry.LastHintW);
        Assert.NotEqual(768, entry.LastHintH);

        // Re-stamp Last* to plausible values, then drop maximized.
        entry.LastHintW = 1024;
        entry.LastHintH = 768;
        h.Host.SetToplevelMaximizedState(new WindowProxy(handle), maximized: false);
        Assert.False(entry.XdgMaximized);
        Assert.NotEqual(1024, entry.LastHintW);
        Assert.NotEqual(768, entry.LastHintH);
    }

    [Fact]
    public void SetToplevelMaximizedState_UnknownHandle_IsNoOp()
    {
        var h = Build();
        // Must tolerate unknown / zero proxies the same way
        // InvalidateFloatRect does.
        h.Host.SetToplevelMaximizedState(new WindowProxy(new IntPtr(0xDEAD0)), true);
        h.Host.SetToplevelMaximizedState(WindowProxy.Zero, false);
        Assert.False(h.Windows.ContainsKey(new IntPtr(0xDEAD0)));
        Assert.False(h.Windows.ContainsKey(IntPtr.Zero));
    }

    [Fact]
    public void InvalidateFloatRect_IsIdempotent()
    {
        var h = Build();
        var handle = new IntPtr(0xF00D);
        var entry = new WindowEntry { HasFloatRect = true, LastPosX = 5, LastPosY = 6 };
        h.Windows[handle] = entry;

        h.Host.InvalidateFloatRect(new WindowProxy(handle));
        var pX = entry.LastPosX;
        var pY = entry.LastPosY;
        var hW = entry.LastHintW;
        var hH = entry.LastHintH;

        // Second call: no change, no throw.
        h.Host.InvalidateFloatRect(new WindowProxy(handle));

        Assert.False(entry.HasFloatRect);
        Assert.Equal(pX, entry.LastPosX);
        Assert.Equal(pY, entry.LastPosY);
        Assert.Equal(hW, entry.LastHintW);
        Assert.Equal(hH, entry.LastHintH);
    }
}
