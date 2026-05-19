using System;
using System.Collections.Generic;
using Aqueous.Features.Compositor.River.Layout;
using Aqueous.Features.Layout;
using Xunit;

namespace Aqueous.Tests.Features.Layout;

/// <summary>
/// Stage 5 unit tests for the <see cref="LayoutProposer"/> facade.
/// The facade is intentionally a thin delegate to
/// <see cref="ILayoutProposerCollaborators"/>; these tests pin that
/// contract so a later (Stage 5b) literal migration of the 762-line
/// proposer math has a behavioural anchor.
/// </summary>
public sealed class LayoutProposerTests
{
    private sealed class FakeCollab : ILayoutProposerCollaborators
    {
        public int ProposeForAreaCalls;
        public IntPtr LastOutput;
        public string? LastOutputName;
        public Rect LastUsableArea;
        public bool FloatActiveDefault;
        public bool FloatActiveByOutput;
        public IntPtr LastFloatProbeOutput;
        public IReadOnlyList<WindowEntryView> NextSnapshot = Array.Empty<WindowEntryView>();
        public string? NextResolvedName;
        public IntPtr? NextNeighbor;
        public IntPtr LastNeighborCurrent;

        public void ProposeForArea(IntPtr output, string? outputName, Rect usableArea)
        {
            ProposeForAreaCalls++;
            LastOutput = output;
            LastOutputName = outputName;
            LastUsableArea = usableArea;
        }

        public bool IsFloatLayoutActive() => FloatActiveDefault;

        public bool IsFloatLayoutActive(IntPtr output)
        {
            LastFloatProbeOutput = output;
            return FloatActiveByOutput;
        }

        public IReadOnlyList<WindowEntryView> BuildSnapshotFor(IntPtr output) => NextSnapshot;

        public string? ResolveOutputName(IntPtr output) => NextResolvedName;

        public IntPtr? LayoutFocusNeighbor(IntPtr output, string? outputName, IntPtr current,
            FocusDirection dir, IReadOnlyList<WindowEntryView> snapshot)
        {
            LastNeighborCurrent = current;
            return NextNeighbor;
        }
    }

    [Fact]
    public void Ctor_NullCollaborator_Throws()
    {
        Assert.Throws<ArgumentNullException>(() => new LayoutProposer(null!));
    }

    [Fact]
    public void ProposeForArea_ForwardsAllArguments()
    {
        var c = new FakeCollab();
        var p = new LayoutProposer(c);
        var rect = new Rect(10, 20, 1900, 1060);
        p.ProposeForArea(new IntPtr(0x100), "DP-1", rect);
        Assert.Equal(1, c.ProposeForAreaCalls);
        Assert.Equal(new IntPtr(0x100), c.LastOutput);
        Assert.Equal("DP-1", c.LastOutputName);
        Assert.Equal(rect, c.LastUsableArea);
    }

    [Fact]
    public void IsFloatLayoutActive_NoArg_ForwardsToCollab()
    {
        var c = new FakeCollab { FloatActiveDefault = true };
        var p = new LayoutProposer(c);
        Assert.True(p.IsFloatLayoutActive());
    }

    [Fact]
    public void IsFloatLayoutActive_PerOutput_ForwardsArg()
    {
        var c = new FakeCollab { FloatActiveByOutput = true };
        var p = new LayoutProposer(c);
        Assert.True(p.IsFloatLayoutActive(new IntPtr(0x200)));
        Assert.Equal(new IntPtr(0x200), c.LastFloatProbeOutput);
    }

    [Fact]
    public void BuildSnapshotFor_ForwardsResult()
    {
        var snap = new[] { new WindowEntryView(new IntPtr(0x1), 0, 0, 0, 0, false, false, 0u) };
        var c = new FakeCollab { NextSnapshot = snap };
        var p = new LayoutProposer(c);
        Assert.Same(snap, p.BuildSnapshotFor(new IntPtr(0x100)));
    }

    [Fact]
    public void ResolveOutputName_ForwardsResult()
    {
        var c = new FakeCollab { NextResolvedName = "HDMI-A-1" };
        var p = new LayoutProposer(c);
        Assert.Equal("HDMI-A-1", p.ResolveOutputName(new IntPtr(0x100)));
    }

    [Fact]
    public void LayoutFocusNeighbor_ForwardsCurrentAndResult()
    {
        var c = new FakeCollab { NextNeighbor = new IntPtr(0x42) };
        var p = new LayoutProposer(c);
        var r = p.LayoutFocusNeighbor(new IntPtr(0x100), "DP-1", new IntPtr(0x7),
            FocusDirection.Right, Array.Empty<WindowEntryView>());
        Assert.Equal(new IntPtr(0x42), r);
        Assert.Equal(new IntPtr(0x7), c.LastNeighborCurrent);
    }

    [Fact]
    public void LayoutFocusNeighbor_NullPropagatesAsNull()
    {
        var c = new FakeCollab { NextNeighbor = null };
        var p = new LayoutProposer(c);
        var r = p.LayoutFocusNeighbor(new IntPtr(0x100), null, new IntPtr(0x7),
            FocusDirection.Left, Array.Empty<WindowEntryView>());
        Assert.Null(r);
    }
}
