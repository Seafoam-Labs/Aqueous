using System.Linq;
using System.Reflection;
using Aqueous.Features.Compositor.River;
using Microsoft.Extensions.Hosting;
using Xunit;

namespace Aqueous.Tests.Compositor.River;

/// <summary>
/// PR 9.12 §2.13 Step 10 — regression guards for <see cref="RiverCompositorHost"/>.
/// The host now owns the Wayland lifecycle directly (god-class
/// <c>RiverWindowManagerClient</c> retired); ctor takes fine-grained
/// DI collaborators rather than an opaque <c>IServiceProvider</c>.
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
    public void RiverCompositorHost_has_single_ctor_with_fine_grained_collaborators()
    {
        var ctors = typeof(RiverCompositorHost).GetConstructors(BindingFlags.Public | BindingFlags.Instance);
        Assert.Single(ctors);
        var p = ctors[0].GetParameters();
        // 13 required collaborators + optional ILogger = 14 params total.
        Assert.True(p.Length >= 13, $"expected >=13 ctor args, found {p.Length}");
        // None of them should be IServiceProvider — the host no longer
        // resolves services lazily through DI.
        Assert.DoesNotContain(p, x => x.ParameterType == typeof(System.IServiceProvider));
    }

    [Fact]
    public void RiverCompositorHost_exposes_StartAsync_and_StopAsync()
    {
        var t = typeof(RiverCompositorHost);
        Assert.NotNull(t.GetMethod(nameof(IHostedService.StartAsync)));
        Assert.NotNull(t.GetMethod(nameof(IHostedService.StopAsync)));
    }
}
