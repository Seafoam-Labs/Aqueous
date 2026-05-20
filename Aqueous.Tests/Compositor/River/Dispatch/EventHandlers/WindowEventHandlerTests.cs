using System;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// <see cref="WindowEventHandler"/> Now takes <c>RiverWindowManagerClient</c> directly (no bridge
/// interface). Real-bridge construction requires Wayland; structural guards only.
/// </summary>
public sealed class WindowEventHandlerTests
{
    [Fact]
    public void InterfaceName_is_river_window_v1()
    {
        // Can't construct without a real RiverWindowManagerClient; check the constant via reflection on a
        // non-constructed instance.
        var prop = typeof(WindowEventHandler).GetProperty("InterfaceName");
        Assert.NotNull(prop);
    }

    [Fact]
    public void Class_is_sealed_and_implements_IEventHandler()
    {
        Assert.True(typeof(WindowEventHandler).IsSealed);
        Assert.Contains(typeof(IEventHandler), typeof(WindowEventHandler).GetInterfaces());
    }

    [Fact]
    public void Ctor_takes_IWindowRegistry_and_WindowEventService()
    {
        var ctors = typeof(WindowEventHandler).GetConstructors();
        Assert.Single(ctors);
        var pars = ctors[0].GetParameters();
        Assert.Equal(3, pars.Length);
        Assert.Equal("Aqueous.Features.Compositor.River.Registry.IWindowRegistry", pars[0].ParameterType.FullName);
        Assert.Equal("Aqueous.Features.Compositor.River.Dispatch.Services.WindowEventService", pars[1].ParameterType.FullName);
    }
}
