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

    // PR 9.12 §2.13 Step 4: LayoutProposer cut off RiverWindowManagerClient;
    // ctor now takes 7 fine-grained DI singletons.
    [Fact]
    public void Ctor_DoesNotTake_RiverWindowManagerClient()
    {
        var ctor = typeof(LayoutProposer).GetConstructors().Single();
        var paramTypes = ctor.GetParameters().Select(p => p.ParameterType).ToArray();
        Assert.DoesNotContain(
            typeof(Aqueous.Features.Compositor.River.RiverWindowManagerClient),
            paramTypes);
        Assert.Equal(7, paramTypes.Length);
        Assert.Equal(typeof(LayoutController), paramTypes[0]);
    }

    [Fact]
    public void Is_sealed()
    {
        Assert.True(typeof(LayoutProposer).IsSealed);
    }
}
