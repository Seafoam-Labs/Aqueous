using System;
using Aqueous.Features.Focus;
using Xunit;

namespace Aqueous.Tests.Features.Focus;

/// <summary>
/// Pins the monotonic focus-tick behaviour on <see cref="FocusedWindowTracker"/>
/// (consumed by <c>GameModeLayout</c> for anchor tie-breaking). <c>GameModeLayout</c> uses
/// <see cref="FocusedWindowTracker.CurrentTick"/> (mirrored onto each
/// <c>WindowEntry.LastFocusTick</c> by <c>LayoutProposer</c>) to break ties when more than
/// one anchor candidate is visible on the same output ("most-recently-focused wins"). These
/// tests pin the contract that the tick:
/// <list type="bullet">
/// <item>Starts at 0.</item>
/// <item>Increments by 1 on every transition to a different non-zero handle.</item>
/// <item>Does <em>not</em> increment when the same handle is re-assigned (no real focus change).</item>
/// <item>Does <em>not</em> increment when focus is cleared (handle set to <see cref="IntPtr.Zero"/>);
///     this keeps the relative ordering across windows stable across blur/refocus cycles.</item>
/// </list>
/// </summary>
public class FocusedWindowTrackerTickTests
{
    [Fact]
    public void CurrentTick_StartsAtZero()
    {
        var t = new FocusedWindowTracker();
        Assert.Equal(0L, t.CurrentTick);
        Assert.Equal(IntPtr.Zero, t.Current);
    }

    [Fact]
    public void Tick_BumpsOnTransitionToNonZeroHandle()
    {
        var t = new FocusedWindowTracker();
        t.Current = new IntPtr(1);
        Assert.Equal(1L, t.CurrentTick);

        t.Current = new IntPtr(2);
        Assert.Equal(2L, t.CurrentTick);

        t.Current = new IntPtr(3);
        Assert.Equal(3L, t.CurrentTick);
    }

    [Fact]
    public void Tick_DoesNotBumpOnSameHandleReassignment()
    {
        var t = new FocusedWindowTracker();
        t.Current = new IntPtr(1);
        Assert.Equal(1L, t.CurrentTick);

        // Setting the same handle again — not a real focus change.
        t.Current = new IntPtr(1);
        t.Current = new IntPtr(1);
        Assert.Equal(1L, t.CurrentTick);
    }

    [Fact]
    public void Tick_DoesNotBumpOnClearToZero()
    {
        var t = new FocusedWindowTracker();
        t.Current = new IntPtr(1);
        t.Current = new IntPtr(2);
        Assert.Equal(2L, t.CurrentTick);

        // Clearing focus (e.g. close of focused window) should NOT bump the counter —
        // the previously-focused window's tick must remain its monotone "last focused at"
        // stamp so anchor selection stays deterministic across blur/refocus cycles.
        t.Current = IntPtr.Zero;
        Assert.Equal(2L, t.CurrentTick);

        // Re-focusing a (possibly different) window bumps normally.
        t.Current = new IntPtr(3);
        Assert.Equal(3L, t.CurrentTick);
    }

    [Fact]
    public void Tick_IsMonotonic_AcrossInterleavedTransitions()
    {
        var t = new FocusedWindowTracker();
        long prev = t.CurrentTick;
        for (int i = 1; i <= 50; i++)
        {
            t.Current = new IntPtr(i);
            Assert.True(t.CurrentTick > prev,
                $"tick must be strictly increasing across distinct-handle transitions; " +
                $"i={i} prev={prev} now={t.CurrentTick}");
            prev = t.CurrentTick;
        }
    }
}
