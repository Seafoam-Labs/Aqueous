using System;
using System.Collections.Generic;
using Aqueous.Features.Layout;
using Aqueous.Features.Layout.Builtin;
using Xunit;

namespace Aqueous.Tests.Features.Layout;

/// <summary>
/// <c>MoveFocused</c> coverage for layouts that previously inherited the
/// interface's default no-op: <see cref="MonocleLayout"/> (z-stack reorder) and
/// <see cref="FloatingLayout"/> (explicit no-op).
/// GameMode coverage lives in <see cref="GameModeLayoutTests"/>.
/// </summary>
public class MoveFocusedTests
{
    private static readonly Rect Area = new(0, 0, 1920, 1080);

    private static WindowEntryView View(int handle) => new(
        Handle: new IntPtr(handle),
        MinW: 0, MinH: 0, MaxW: 0, MaxH: 0,
        Floating: false, Fullscreen: false, Tags: 1u);

    // ---------- MonocleLayout ----------

    private static (MonocleLayout engine, object? state) HydrateMonocle(params int[] handles)
    {
        var engine = new MonocleLayout();
        var windows = new List<WindowEntryView>();
        foreach (var h in handles) windows.Add(View(h));
        object? state = null;
        engine.Arrange(Area, windows, new IntPtr(handles[0]), LayoutOptions.Default, ref state);
        return (engine, state);
    }

    [Fact]
    public void Monocle_MoveFocused_Right_SwapsWithNext()
    {
        var (engine, state) = HydrateMonocle(1, 2, 3);
        Assert.True(engine.MoveFocused(IntPtr.Zero, new IntPtr(2), FocusDirection.Right, ref state));
    }

    [Fact]
    public void Monocle_MoveFocused_Left_SwapsWithPrev()
    {
        var (engine, state) = HydrateMonocle(1, 2, 3);
        Assert.True(engine.MoveFocused(IntPtr.Zero, new IntPtr(2), FocusDirection.Left, ref state));
    }

    [Fact]
    public void Monocle_MoveFocused_AtStart_LeftReturnsFalse()
    {
        var (engine, state) = HydrateMonocle(1, 2, 3);
        Assert.False(engine.MoveFocused(IntPtr.Zero, new IntPtr(1), FocusDirection.Left, ref state));
    }

    [Fact]
    public void Monocle_MoveFocused_AtEnd_RightReturnsFalse()
    {
        var (engine, state) = HydrateMonocle(1, 2, 3);
        Assert.False(engine.MoveFocused(IntPtr.Zero, new IntPtr(3), FocusDirection.Right, ref state));
    }

    [Fact]
    public void Monocle_MoveFocused_UnknownHandle_ReturnsFalse()
    {
        var (engine, state) = HydrateMonocle(1, 2);
        Assert.False(engine.MoveFocused(IntPtr.Zero, new IntPtr(0xDEAD), FocusDirection.Right, ref state));
    }

    [Fact]
    public void Monocle_MoveFocused_NoState_ReturnsFalse()
    {
        var engine = new MonocleLayout();
        object? state = null;
        Assert.False(engine.MoveFocused(IntPtr.Zero, new IntPtr(1), FocusDirection.Right, ref state));
    }

    [Fact]
    public void Monocle_MoveFocused_UpDown_BehaveLikeLeftRight()
    {
        var (engine, state) = HydrateMonocle(1, 2, 3);
        Assert.True(engine.MoveFocused(IntPtr.Zero, new IntPtr(2), FocusDirection.Down, ref state));
        Assert.True(engine.MoveFocused(IntPtr.Zero, new IntPtr(2), FocusDirection.Up, ref state));
        // Edges
        Assert.False(engine.MoveFocused(IntPtr.Zero, new IntPtr(1), FocusDirection.Up, ref state));
    }

    // ---------- FloatingLayout ----------

    [Theory]
    [InlineData(FocusDirection.Left)]
    [InlineData(FocusDirection.Right)]
    [InlineData(FocusDirection.Up)]
    [InlineData(FocusDirection.Down)]
    [InlineData(FocusDirection.Prev)]
    [InlineData(FocusDirection.Next)]
    public void Floating_MoveFocused_AnyDirection_ReturnsFalse(FocusDirection dir)
    {
        var engine = new FloatingLayout();
        var windows = new List<WindowEntryView> { View(1), View(2) };
        object? state = null;
        engine.Arrange(Area, windows, new IntPtr(1), LayoutOptions.Default, ref state);

        Assert.False(engine.MoveFocused(IntPtr.Zero, new IntPtr(1), dir, ref state));
    }

    [Fact]
    public void Floating_MoveFocused_DoesNotMutateState()
    {
        var engine = new FloatingLayout();
        var windows = new List<WindowEntryView> { View(1), View(2) };
        object? state = null;
        var before = engine.Arrange(Area, windows, new IntPtr(1), LayoutOptions.Default, ref state);
        var stateBefore = state;

        engine.MoveFocused(IntPtr.Zero, new IntPtr(1), FocusDirection.Right, ref state);

        Assert.Same(stateBefore, state);
        var after = engine.Arrange(Area, windows, new IntPtr(1), LayoutOptions.Default, ref state);
        Assert.Equal(before.Count, after.Count);
        for (int i = 0; i < before.Count; i++)
        {
            Assert.Equal(before[i].Geometry, after[i].Geometry);
        }
    }
}
