using System;
using Aqueous.Features.Bindings;
using Xunit;

namespace Aqueous.Tests.Features.Bindings;

/// <summary>
/// Service-level facade tests for the key-bindings subsystem. Covers the
/// <see cref="ProcessLauncher"/> smoke path and the null-argument regression guards that pin the
/// public constructor surfaces of the binding services.
/// </summary>
public class Stage7Tests
{
    // - ProcessLauncher -------------------------------------------------

    [Fact]
    public void ProcessLauncher_EmptyFileName_ReturnsFalse()
    {
        var pl = new ProcessLauncher();
        Assert.False(pl.Start(string.Empty));
    }

    [Fact]
    public void ProcessLauncher_NonexistentBinary_DoesNotThrow_ReturnsFalse()
    {
        var pl = new ProcessLauncher();
        var ok = pl.Start("/this/path/does/not/exist_aqueous_stage7");
        Assert.False(ok);
    }

    [Fact]
    public void ProcessLauncher_TrueBinary_StartsAndReturnsTrue()
    {
        if (!System.IO.File.Exists("/bin/true")) return;
        var pl = new ProcessLauncher();
        Assert.True(pl.Start("/bin/true"));
    }

    // - Null-ctor guards for the three facades --------------------------

    [Fact]
    public void CustomActionRunner_NullCtorArg_Throws()
        => Assert.Throws<ArgumentNullException>(() => new CustomActionRunner(null!, null!, null!));

    [Fact]
    public void KeyBindingRouter_NullCtorArg_Throws()
        => Assert.Throws<ArgumentNullException>(() => new KeyBindingRouter(null!, null!, null!, null!, null!, null!, null!, null!));

    [Fact]
    public void KeyBindingRegistrar_NullCtorArg_Throws()
        => Assert.Throws<ArgumentNullException>(() => new KeyBindingRegistrar(null!, null!, null!, null!, null!));

    // - Interface-surface guards ---------------------------------------

    [Fact]
    public void Stage7_PublicInterfaces_HaveDocumentedSurface()
    {
        Assert.NotNull(typeof(IProcessLauncher).GetMethod("Start"));
        Assert.NotNull(typeof(ICustomActionRunner).GetMethod("Run"));
        Assert.NotNull(typeof(IKeyBindingRouter).GetMethod("Handle"));
        Assert.NotNull(typeof(IKeyBindingRegistrar).GetMethod("RegisterAllBindings"));
        Assert.NotNull(typeof(IKeyBindingRegistrar).GetMethod("IsRegistered"));
    }
}
