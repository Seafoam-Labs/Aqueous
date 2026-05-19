using System;
using System.Linq;
using System.Reflection;
using Xunit;

namespace Aqueous.Tests.Compositor.River;

/// <summary>
/// regression guards: pin the retirement of
/// <c>IRegistryHandlerCollaborators</c> and its bridge partial, plus the
/// new direct-dependency wiring of <c>RegistryEventHandler</c> on
/// <c>RegistryBinder</c>.
/// </summary>
public sealed class RegressionGuardsRetirementOfIRegistryHandlerCollaborators
{
    private static Assembly ProductionAssembly()
        => typeof(Aqueous.Features.Compositor.River.RiverWindowManagerClient).Assembly;

    [Fact]
    public void IRegistryHandlerCollaborators_type_no_longer_exists()
    {
        var t = ProductionAssembly().GetType(
            "Aqueous.Features.Compositor.River.Dispatch.EventHandlers.IRegistryHandlerCollaborators",
            throwOnError: false);
        Assert.Null(t);
    }

    [Fact]
    public void RiverWindowManagerClient_does_not_implement_IRegistryHandlerCollaborators()
    {
        var t = typeof(Aqueous.Features.Compositor.River.RiverWindowManagerClient);
        Assert.DoesNotContain(t.GetInterfaces(),
            i => i.FullName ==
                "Aqueous.Features.Compositor.River.Dispatch.EventHandlers.IRegistryHandlerCollaborators");
    }

    [Fact]
    public void RegistryEventHandler_ctor_takes_RegistryBinder_directly()
    {
        var t = typeof(Aqueous.Features.Compositor.River.Dispatch.EventHandlers.RegistryEventHandler);
        var ctor = Assert.Single(t.GetConstructors(BindingFlags.Public | BindingFlags.Instance));
        var parms = ctor.GetParameters();
        Assert.Equal(2, parms.Length);
        Assert.Equal(
            typeof(Aqueous.Features.Compositor.River.Connection.RegistryBinder),
            parms[0].ParameterType);
        Assert.Equal(typeof(Action<string>), parms[1].ParameterType);
        Assert.True(parms[1].IsOptional);
    }

    [Fact]
    public void RegistryEventHandler_ctor_null_guard()
    {
        Assert.Throws<ArgumentNullException>(() =>
            new Aqueous.Features.Compositor.River.Dispatch.EventHandlers.RegistryEventHandler(
                null!, log: null));
    }

    [Fact]
    public void RegistryEventHandler_InterfaceName_is_wl_registry()
    {
        var h = new Aqueous.Features.Compositor.River.Dispatch.EventHandlers.RegistryEventHandler(
            new Aqueous.Features.Compositor.River.Connection.RegistryBinder(), log: null);
        Assert.Equal("wl_registry", h.InterfaceName);
    }

    [Fact]
    public void RiverWindowManagerClient_exposes_RegistryBinder_accessor()
    {
        var p = typeof(Aqueous.Features.Compositor.River.RiverWindowManagerClient)
            .GetProperty("RegistryBinder",
                BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
        Assert.NotNull(p);
        Assert.Equal(
            typeof(Aqueous.Features.Compositor.River.Connection.RegistryBinder),
            p!.PropertyType);
    }
}
