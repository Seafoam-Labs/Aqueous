using System;
using System.Linq;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// Stage 9 PR 9.6: <c>ISeatHandlerCollaborators</c> bridge retired.
/// <see cref="SeatEventHandler"/> now consumes <see cref="RiverWindowManagerClient"/>
/// directly via pass-through methods, which cannot be unit-tested in
/// isolation (no DI-safe way to construct the god class without a live
/// Wayland connection). Behaviour-level coverage migrates to integration
/// smoke tests; this file retains structural guards only.
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
    public void SeatEventHandler_Ctor_DoesNotTake_RiverWindowManagerClient()
    {
        // PR 9.12 §2.13 Step 3: SeatEventHandler no longer depends on
        // the god class. The six seat-bridge methods previously called
        // via _river.* live on SeatInteractionService, which consumes
        // fine-grained DI singletons directly.
        var ctor = typeof(SeatEventHandler).GetConstructors().Single();
        var p = ctor.GetParameters();
        // Order: seats, windows, seatHoveredWindow, seatPointerPos,
        //        interaction, log.
        Assert.Equal(6, p.Length);
        Assert.DoesNotContain(p, x => x.ParameterType == typeof(RiverWindowManagerClient));
        Assert.Equal(typeof(SeatInteractionService), p[4].ParameterType);
    }

    [Fact]
    public void ISeatHandlerCollaborators_Type_Deleted()
    {
        var asm = typeof(RiverWindowManagerClient).Assembly;
        var t = asm.GetType(
            "Aqueous.Features.Compositor.River.Dispatch.EventHandlers.ISeatHandlerCollaborators");
        Assert.Null(t);
    }
}
