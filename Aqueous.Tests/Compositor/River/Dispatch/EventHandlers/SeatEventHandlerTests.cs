using System.Linq;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// Structural guards for <see cref="SeatEventHandler"/>. retired the class negative-shape pins
/// together with <c>RiverWindowManagerClient</c> itself.
/// </summary>
public sealed class SeatEventHandlerTests
{
    [Fact]
    public void SeatEventHandler_Implements_IEventHandler_With_Correct_Interface_Name()
    {
        Assert.Contains(typeof(IEventHandler), typeof(SeatEventHandler).GetInterfaces());
        Assert.True(typeof(SeatEventHandler).IsSealed);
    }

    [Fact]
    public void SeatEventHandler_Ctor_Takes_SeatInteractionService()
    {
        var ctor = typeof(SeatEventHandler).GetConstructors().Single();
        var p = ctor.GetParameters();
        Assert.Equal(6, p.Length);
        Assert.Equal(typeof(SeatInteractionService), p[4].ParameterType);
    }

    [Fact]
    public void ISeatHandlerCollaborators_Type_Deleted()
    {
        var asm = typeof(RiverCompositorHost).Assembly;
        var t = asm.GetType(
            "Aqueous.Features.Compositor.River.Dispatch.EventHandlers.ISeatHandlerCollaborators");
        Assert.Null(t);
    }
}
