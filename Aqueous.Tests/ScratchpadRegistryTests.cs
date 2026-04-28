using System;
using Aqueous.Features.State;
using Xunit;

namespace Aqueous.Tests;

/// <summary>
/// Phase 3 — coverage tests for <see cref="ScratchpadRegistry"/>. Each
/// pad holds at most one window; lookups, evictions and forgetting are
/// pure dictionary operations with no compositor dependency.
/// </summary>
public class ScratchpadRegistryTests
{
    private static WindowProxy W(int h) => new(new IntPtr(h));

    [Fact]
    public void Get_UnknownPad_ReturnsZero()
    {
        var reg = new ScratchpadRegistry();
        Assert.True(reg.Get("nope").IsZero);
        Assert.False(reg.IsOccupied("nope"));
    }

    [Fact]
    public void Assign_NewSlot_ReturnsZeroPriorOccupant()
    {
        var reg = new ScratchpadRegistry();
        var prior = reg.Assign(ScratchpadRegistry.DefaultPad, W(7));
        Assert.True(prior.IsZero);
        Assert.Equal(W(7), reg.Get(ScratchpadRegistry.DefaultPad));
        Assert.True(reg.IsOccupied(ScratchpadRegistry.DefaultPad));
    }

    [Fact]
    public void Assign_Existing_EvictsAndReturnsPrior()
    {
        var reg = new ScratchpadRegistry();
        reg.Assign("term", W(1));
        var prior = reg.Assign("term", W(2));
        Assert.Equal(W(1), prior);
        Assert.Equal(W(2), reg.Get("term"));
    }

    [Fact]
    public void Forget_KnownWindow_ReturnsPadName_AndClearsSlot()
    {
        var reg = new ScratchpadRegistry();
        reg.Assign("a", W(1));
        reg.Assign("b", W(2));
        var name = reg.Forget(W(1));
        Assert.Equal("a", name);
        Assert.False(reg.IsOccupied("a"));
        Assert.True(reg.IsOccupied("b"));
    }

    [Fact]
    public void Forget_UnknownWindow_ReturnsNull()
    {
        var reg = new ScratchpadRegistry();
        reg.Assign("a", W(1));
        Assert.Null(reg.Forget(W(99)));
    }

    [Fact]
    public void Clear_RemovesSlot_RegardlessOfOccupant()
    {
        var reg = new ScratchpadRegistry();
        reg.Assign("a", W(1));
        reg.Clear("a");
        Assert.False(reg.IsOccupied("a"));
        // Clearing a non-existent slot is a no-op.
        reg.Clear("never");
    }

    [Fact]
    public void Pads_Snapshot_ReflectsAssignedSlots()
    {
        var reg = new ScratchpadRegistry();
        reg.Assign("a", W(1));
        reg.Assign("b", W(2));
        Assert.Equal(2, reg.Pads.Count);
        Assert.Contains("a", reg.Pads.Keys);
        Assert.Contains("b", reg.Pads.Keys);
    }

    [Fact]
    public void IsOccupied_FalseForExplicitlyZeroAssignment()
    {
        var reg = new ScratchpadRegistry();
        reg.Assign("a", WindowProxy.Zero);
        Assert.False(reg.IsOccupied("a"));
    }
}
