using System;
using System.Linq;
using System.Reflection;
using Aqueous.Features.Bindings;
using Aqueous.Features.Compositor.River;
using Xunit;

namespace Aqueous.Tests.Features.Bindings;

/// <summary>
/// Stage 7 facade tests + Stage 9 PR 9.9 regression guards. The bridge
/// interface IKeyBindingsCollaborators was retired in PR 9.9; the
/// service ctors now take RiverWindowManagerClient directly. Bridge-
/// coupled forwarding tests removed (cannot construct RWMC in a unit
/// test); structural reflection guards retained.
/// </summary>
public class Stage7Tests
{
    // --- ProcessLauncher -------------------------------------------------

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

    // --- Null-ctor guards for the three facades --------------------------

    [Fact]
    public void CustomActionRunner_NullCtorArg_Throws()
        => Assert.Throws<ArgumentNullException>(() => new CustomActionRunner(null!, null!, null!));

    [Fact]
    public void KeyBindingRouter_NullCtorArg_Throws()
        => Assert.Throws<ArgumentNullException>(() => new KeyBindingRouter(null!, null!, null!, null!, null!, null!));

    [Fact]
    public void KeyBindingRegistrar_NullCtorArg_Throws()
        => Assert.Throws<ArgumentNullException>(() => new KeyBindingRegistrar(null!));

    // --- Structural guards (Stage 7 + PR 9.9) ----------------------------

    [Fact]
    public void Stage7_GodClass_HasBindingsServiceFields()
    {
        var fields = typeof(RiverWindowManagerClient).GetFields(
            BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.Contains(fields, f => f.Name == "_keyBindingRegistrar" && f.FieldType == typeof(IKeyBindingRegistrar));
        Assert.Contains(fields, f => f.Name == "_keyBindingRouter" && f.FieldType == typeof(IKeyBindingRouter));
        Assert.Contains(fields, f => f.Name == "_customActionRunner" && f.FieldType == typeof(ICustomActionRunner));
        Assert.Contains(fields, f => f.Name == "_processLauncher" && f.FieldType == typeof(IProcessLauncher));
    }

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

/// <summary>
/// PR 9.9 (Stage 9): regression guards confirming the
/// IKeyBindingsCollaborators bridge has been retired and the bindings
/// trio now consumes RiverWindowManagerClient directly via pass-through
/// accessors (Shape-A pattern from PRs 9.3–9.8).
/// </summary>
public class Stage9Pr99Tests
{
    private static Type? FindRiverType(string name)
        => typeof(RiverWindowManagerClient).Assembly.GetTypes()
            .FirstOrDefault(t => t.Name == name && t.Namespace == "Aqueous.Features.Compositor.River.Bindings");

    [Fact]
    public void IKeyBindingsCollaborators_Type_Deleted()
        => Assert.Null(FindRiverType("IKeyBindingsCollaborators"));

    [Fact]
    public void GodClass_NoLongerImplements_IKeyBindingsCollaborators()
    {
        var impls = typeof(RiverWindowManagerClient).GetInterfaces()
            .Select(t => t.FullName)
            .Where(n => n is not null)
            .ToArray();
        Assert.DoesNotContain(impls, n => n!.EndsWith(".IKeyBindingsCollaborators", StringComparison.Ordinal));
    }

    [Fact]
    public void KeyBindingRegistrar_Ctor_TakesRiverWindowManagerClient()
    {
        var ctor = typeof(KeyBindingRegistrar).GetConstructors().Single();
        var p = ctor.GetParameters().Single();
        Assert.Equal(typeof(RiverWindowManagerClient), p.ParameterType);
    }

    // PR 9.12 §2.13: the residual RiverWindowManagerClient ctor argument is
    // gone from both routers — LayoutConfig is reached through
    // LayoutController, the default config path through
    // Aqueous.Features.Configuration.DefaultConfigPath, and the static Log
    // helper requires no instance. Pin both ctors to fine-grained services
    // only.
    [Fact]
    public void KeyBindingRouter_Ctor_DoesNotTake_RiverWindowManagerClient()
    {
        var ctor = typeof(KeyBindingRouter).GetConstructors().Single();
        Assert.DoesNotContain(ctor.GetParameters(), p => p.ParameterType == typeof(RiverWindowManagerClient));
        Assert.True(ctor.GetParameters().Length >= 2,
            "router ctor expected to take fine-grained services");
    }

    [Fact]
    public void CustomActionRunner_Ctor_DoesNotTake_RiverWindowManagerClient()
    {
        var ctor = typeof(CustomActionRunner).GetConstructors().Single();
        Assert.DoesNotContain(ctor.GetParameters(), p => p.ParameterType == typeof(RiverWindowManagerClient));
        Assert.True(ctor.GetParameters().Length >= 2,
            "runner ctor expected to take fine-grained services");
    }

    // PR 9.12 §2.6: the two retired dispatch forwarders
    // (HandleKeyBindingActionForwarding / RunCustomActionForwarding) were
    // never reached by production code — the routers are invoked directly
    // via the DI-injected fields. Only RegisterAllBindingsForwarding +
    // IsBindingRegisteredForwarding remain (called by KeyBindingRegistrar).
    [Theory]
    [InlineData("RegisterAllBindingsForwarding")]
    [InlineData("IsBindingRegisteredForwarding")]
    public void GodClass_Has_PassThrough_Accessor(string name)
    {
        var m = typeof(RiverWindowManagerClient).GetMethod(
            name,
            BindingFlags.NonPublic | BindingFlags.Instance);
        Assert.NotNull(m);
    }
}
