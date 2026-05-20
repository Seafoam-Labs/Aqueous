using System;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// PR 9.7: <see cref="ManagerEventHandler"/> now takes
/// <c>RiverWindowManagerClient</c> directly (no bridge interface).
/// Real-bridge construction requires Wayland; structural guards only.
/// </summary>
public sealed class ManagerEventHandlerTests
{
    [Fact]
    public void InterfaceName_property_exists()
    {
        var prop = typeof(ManagerEventHandler).GetProperty("InterfaceName");
        Assert.NotNull(prop);
    }

    [Fact]
    public void Class_is_sealed_and_implements_IEventHandler()
    {
        Assert.True(typeof(ManagerEventHandler).IsSealed);
        Assert.Contains(typeof(IEventHandler), typeof(ManagerEventHandler).GetInterfaces());
    }

    [Fact]
    public void Ctor_takes_RiverWindowManagerClient()
    {
        var ctors = typeof(ManagerEventHandler).GetConstructors();
        Assert.Single(ctors);
        var pars = ctors[0].GetParameters();
        Assert.Equal(2, pars.Length);
        Assert.Equal("Aqueous.Features.Compositor.River.RiverWindowManagerClient", pars[0].ParameterType.FullName);
    }
}
