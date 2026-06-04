using System;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// Structural guards for <see cref="ShellSurfaceEventHandler"/>, the handler that turns the new
/// <c>river_shell_surface_v1::destroyed</c> event (opcode 0, since protocol v5) into a deterministic
/// invalidation of pending shell-surface focus. Real construction needs <c>SeatInteractionService</c>,
/// whose own dependencies require Wayland; structural pins only.
/// </summary>
public sealed class ShellSurfaceEventHandlerTests
{
    [Fact]
    public void Class_is_sealed_and_implements_IEventHandler()
    {
        Assert.True(typeof(ShellSurfaceEventHandler).IsSealed);
        Assert.Contains(typeof(IEventHandler), typeof(ShellSurfaceEventHandler).GetInterfaces());
    }

    [Fact]
    public void Ctor_takes_SeatInteractionService()
    {
        var ctors = typeof(ShellSurfaceEventHandler).GetConstructors();
        Assert.Single(ctors);
        var pars = ctors[0].GetParameters();
        Assert.Single(pars);
        Assert.Equal(typeof(SeatInteractionService), pars[0].ParameterType);
    }

    [Fact]
    public void Destroyed_opcode_is_zero()
    {
        Assert.Equal(0u, RiverProtocolOpcodes.ShellSurface.Destroyed);
    }
}
