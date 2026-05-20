using System;
using System.Linq;
using Aqueous.Features.Layout;
using Xunit;

namespace Aqueous.Tests.Features.Layout;

/// <summary>
/// PR 9.8 reduced this suite to structural guards. The
/// <c>ILayoutProposerCollaborators</c> bridge has been retired;
/// <see cref="LayoutProposer"/> now takes the god class directly.
/// Per-method behavioural coverage is gated on manual River smoke
/// because the bodies still live in the partial.
/// </summary>
public sealed class LayoutProposerTests
{
    [Fact]
    public void Ctor_NullClient_Throws()
    {
        Assert.Throws<ArgumentNullException>(() => new LayoutProposer(null!));
    }

    [Fact]
    public void Implements_ILayoutProposer()
    {
        Assert.Contains(typeof(ILayoutProposer), typeof(LayoutProposer).GetInterfaces());
    }

    [Fact]
    public void Ctor_takes_RiverWindowManagerClient()
    {
        var ctor = typeof(LayoutProposer).GetConstructors().Single();
        var paramTypes = ctor.GetParameters().Select(p => p.ParameterType).ToArray();
        Assert.Single(paramTypes);
        Assert.Equal(typeof(Aqueous.Features.Compositor.River.RiverWindowManagerClient), paramTypes[0]);
    }

    [Fact]
    public void Is_sealed()
    {
        Assert.True(typeof(LayoutProposer).IsSealed);
    }
}
