using System;
using System.Linq;
using System.Reflection;
using Aqueous.Features.Compositor.River;
using Microsoft.Extensions.Hosting;
using Xunit;

namespace Aqueous.Tests.Compositor.River;

/// <summary>
/// regression guards: ensure the <see cref="RiverCompositorHost"/>
/// IHostedService shell exists with the documented shape and ctor.
/// progressively migrate state onto it; this suite pins
/// the structural invariants the later PRs depend on.
/// </summary>
public sealed class RegressionGuardsForHostedCompositor
{
    [Fact]
    public void RiverCompositorHost_type_exists_and_is_internal_sealed()
    {
        var t = typeof(RiverCompositorHost);
        Assert.True(t.IsSealed, "RiverCompositorHost must be sealed");
        Assert.False(t.IsPublic, "RiverCompositorHost must be internal");
        Assert.True(t.IsClass);
    }

    [Fact]
    public void RiverCompositorHost_implements_IHostedService()
    {
        Assert.Contains(typeof(IHostedService), typeof(RiverCompositorHost).GetInterfaces());
    }

    [Fact]
    public void RiverCompositorHost_has_ctor_taking_IServiceProvider()
    {
        var ctors = typeof(RiverCompositorHost).GetConstructors(BindingFlags.Public | BindingFlags.Instance);
        Assert.Single(ctors);
        var p = ctors[0].GetParameters();
        Assert.NotEmpty(p);
        Assert.Equal(typeof(IServiceProvider), p[0].ParameterType);
    }

    [Fact]
    public void RiverCompositorHost_ctor_null_provider_throws()
    {
        Assert.Throws<ArgumentNullException>(() => new RiverCompositorHost(null!));
    }

    [Fact]
    public void RiverCompositorHost_exposes_StartAsync_and_StopAsync()
    {
        var t = typeof(RiverCompositorHost);
        Assert.NotNull(t.GetMethod(nameof(IHostedService.StartAsync)));
        Assert.NotNull(t.GetMethod(nameof(IHostedService.StopAsync)));
    }

    [Fact]
    public void RiverCompositorHost_Client_is_null_before_StartAsync()
    {
        var host = new RiverCompositorHost(new EmptyProvider());
        var prop = typeof(RiverCompositorHost).GetProperty(
            "Client", BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.NotNull(prop);
        Assert.Null(prop!.GetValue(host));
    }

    [Fact]
    public void StopAsync_before_StartAsync_is_safe()
    {
        var host = new RiverCompositorHost(new EmptyProvider());
        // Must not throw — disposes null client.
        host.StopAsync(default).GetAwaiter().GetResult();
    }

    private sealed class EmptyProvider : IServiceProvider
    {
        public object? GetService(Type serviceType) => null;
    }
}
