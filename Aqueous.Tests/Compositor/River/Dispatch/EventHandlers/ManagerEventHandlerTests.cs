using System;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// <see cref="ManagerEventHandler"/> Now takes the lifted <c>ManagerEventService</c> directly (no
/// longer the god class). Real-bridge construction requires Wayland; structural guards only.
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
    public void Ctor_takes_ManagerEventService()
    {
        var ctors = typeof(ManagerEventHandler).GetConstructors();
        Assert.Single(ctors);
        var pars = ctors[0].GetParameters();
        Assert.Equal(2, pars.Length);
        Assert.Equal("Aqueous.Features.Compositor.River.Dispatch.Services.ManagerEventService", pars[0].ParameterType.FullName);
    }
}
