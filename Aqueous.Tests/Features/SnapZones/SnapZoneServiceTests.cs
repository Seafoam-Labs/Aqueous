using System;
using System.Collections.Generic;
using Aqueous.Features.Compositor.River.SnapZones;
using Aqueous.Features.SnapZones;
using Xunit;

namespace Aqueous.Tests.Features.SnapZones;

public class SnapZoneServiceTests
{
    private sealed class FakeCollab : ISnapZoneServiceCollaborators
    {
        public int ApplyCalls;
        public int SnapCalls;
        public int CollectCalls;
        public IntPtr LastApplySeat;
        public IntPtr LastSnapSeat;
        public IEnumerable<IReadOnlyList<SnapZoneLayout>> CollectResult { get; set; } =
            Array.Empty<IReadOnlyList<SnapZoneLayout>>();

        public void ApplyLiveSnapPreviewImpl(IntPtr seat)
        {
            ApplyCalls++;
            LastApplySeat = seat;
        }

        public void TrySnapDraggedWindowToZoneImpl(IntPtr seat)
        {
            SnapCalls++;
            LastSnapSeat = seat;
        }

        public IEnumerable<IReadOnlyList<SnapZoneLayout>> CollectAllSnapLayoutsImpl()
        {
            CollectCalls++;
            return CollectResult;
        }
    }

    [Fact]
    public void Ctor_NullCollaborator_Throws()
    {
        Assert.Throws<ArgumentNullException>(() => new SnapZoneService(null!));
    }

    [Fact]
    public void ApplyLiveSnapPreview_ForwardsToCollaborator()
    {
        var c = new FakeCollab();
        var svc = new SnapZoneService(c);
        svc.ApplyLiveSnapPreview((IntPtr)0x1234);
        Assert.Equal(1, c.ApplyCalls);
        Assert.Equal((IntPtr)0x1234, c.LastApplySeat);
    }

    [Fact]
    public void TrySnapDraggedWindowToZone_ForwardsToCollaborator()
    {
        var c = new FakeCollab();
        var svc = new SnapZoneService(c);
        svc.TrySnapDraggedWindowToZone((IntPtr)0xABCD);
        Assert.Equal(1, c.SnapCalls);
        Assert.Equal((IntPtr)0xABCD, c.LastSnapSeat);
    }

    [Fact]
    public void CollectAllSnapLayouts_ForwardsToCollaborator()
    {
        var c = new FakeCollab();
        var svc = new SnapZoneService(c);
        var result = svc.CollectAllSnapLayouts();
        Assert.Same(c.CollectResult, result);
        Assert.Equal(1, c.CollectCalls);
    }

    [Theory]
    [InlineData(SnapActivator.Always, 0u)]
    [InlineData(SnapActivator.Shift,  Aqueous.Features.Compositor.River.Mods.ModShift)]
    [InlineData(SnapActivator.Ctrl,   Aqueous.Features.Compositor.River.Mods.ModCtrl)]
    [InlineData(SnapActivator.Alt,    Aqueous.Features.Compositor.River.Mods.ModAlt)]
    [InlineData(SnapActivator.Super,  Aqueous.Features.Compositor.River.Mods.ModSuper)]
    public void ActivatorToMask_MatchesProtocolMapping(SnapActivator activator, uint expected)
    {
        var svc = new SnapZoneService(new FakeCollab());
        Assert.Equal(expected, svc.ActivatorToMask(activator));
    }

    [Fact]
    public void ActivatorToMask_UnknownValue_ReturnsZero()
    {
        var svc = new SnapZoneService(new FakeCollab());
        Assert.Equal(0u, svc.ActivatorToMask((SnapActivator)99));
    }

    // Stage 6 Part 1 decomposition guards.

    [Fact]
    public void Bridge_Interface_Exists_And_HasExpectedMembers()
    {
        var t = typeof(ISnapZoneServiceCollaborators);
        Assert.True(t.IsInterface);
        Assert.NotNull(t.GetMethod(nameof(ISnapZoneServiceCollaborators.ApplyLiveSnapPreviewImpl)));
        Assert.NotNull(t.GetMethod(nameof(ISnapZoneServiceCollaborators.TrySnapDraggedWindowToZoneImpl)));
        Assert.NotNull(t.GetMethod(nameof(ISnapZoneServiceCollaborators.CollectAllSnapLayoutsImpl)));
    }

    [Fact]
    public void RiverWindowManagerClient_Implements_ISnapZoneServiceCollaborators()
    {
        var t = typeof(Aqueous.Features.Compositor.River.RiverWindowManagerClient);
        Assert.Contains(typeof(ISnapZoneServiceCollaborators), t.GetInterfaces());
    }

    [Fact]
    public void SnapZoneService_ImplementsPublicSnapZoneServiceInterface()
    {
        Assert.True(typeof(ISnapZoneService).IsAssignableFrom(typeof(SnapZoneService)));
    }
}
