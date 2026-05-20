using System;
using System.Linq;
using Aqueous.Features.Layout;
using Xunit;

namespace Aqueous.Tests.Features.Layout;

/// <summary>
/// Reduced this suite to structural guards. The <c>ILayoutProposerCollaborators</c> bridge has
/// been retired; <see cref="LayoutProposer"/> now takes the god class directly. Per-method
/// behavioural coverage is gated on manual River smoke because the bodies still live in the
/// partial.
/// </summary>
public sealed class LayoutProposerTests
{
    [Fact]
    public void Ctor_NullArg_Throws()
    {
        Assert.Throws<ArgumentNullException>(() => new LayoutProposer(
            null!, null!, null!, null!, null!, null!, null!));
    }

    [Fact]
    public void Implements_ILayoutProposer()
    {
        Assert.Contains(typeof(ILayoutProposer), typeof(LayoutProposer).GetInterfaces());
    }

    // Negative class ctor-shape pin retired with RiverWindowManagerClient itself.
    [Fact]
    public void Ctor_Takes_LayoutController_First()
    {
        var ctor = typeof(LayoutProposer).GetConstructors().Single();
        var paramTypes = ctor.GetParameters().Select(p => p.ParameterType).ToArray();
        Assert.Equal(7, paramTypes.Length);
        Assert.Equal(typeof(LayoutController), paramTypes[0]);
    }

    [Fact]
    public void Is_sealed()
    {
        Assert.True(typeof(LayoutProposer).IsSealed);
    }
}
