using System.Linq;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Focus;
using Aqueous.Features.Workspaces;
using Xunit;

namespace Aqueous.Tests.Features.Focus;

/// <summary>
/// Structural guards for <see cref="FocusService"/>. retired the class negative-shape pins
/// together with <c>RiverWindowManagerClient</c> itself.
/// </summary>
public sealed class FocusServiceTests
{
    [Fact]
    public void FocusService_Implements_IFocusService()
    {
        Assert.Contains(typeof(IFocusService), typeof(FocusService).GetInterfaces());
        Assert.True(typeof(FocusService).IsSealed);
    }

    [Fact]
    public void FocusService_Ctor_Has_Expected_Shape()
    {
        var ctor = typeof(FocusService).GetConstructors().Single();
        var p = ctor.GetParameters();
        Assert.Equal(11, p.Length);
        Assert.Equal(typeof(FocusedWindowTracker), p[3].ParameterType);
        Assert.Equal(typeof(PendingFocusStore), p[4].ParameterType);
        Assert.Equal(typeof(PrimarySeatTracker), p[5].ParameterType);
        Assert.Equal(typeof(ILayerShellFocusState), p[9].ParameterType);
        Assert.Equal(typeof(WorkspaceStore), p[10].ParameterType);
    }

    [Fact]
    public void IFocusServiceCollaborators_Type_Deleted()
    {
        var asm = typeof(RiverCompositorHost).Assembly;
        var t = asm.GetType("Aqueous.Features.Compositor.River.Focus.IFocusServiceCollaborators");
        Assert.Null(t);
    }
}
