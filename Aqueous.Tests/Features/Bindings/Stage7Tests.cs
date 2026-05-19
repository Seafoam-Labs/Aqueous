using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using Aqueous.Features.Bindings;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Bindings;
using Xunit;

namespace Aqueous.Tests.Features.Bindings;

/// <summary>
/// Stage 7 facade + bridge tests: ProcessLauncher AOT-safety + the four
/// new Shape-A service seams (IProcessLauncher, ICustomActionRunner,
/// IKeyBindingRegistrar, IKeyBindingRouter) all forward through
/// IKeyBindingsCollaborators correctly, plus structural guards.
/// </summary>
public class Stage7Tests
{
    private sealed class FakeBindingsCollab : IKeyBindingsCollaborators
    {
        public List<IntPtr> RegisterCalls { get; } = new();
        public List<IntPtr> IsRegisteredCalls { get; } = new();
        public List<KeyBindingAction> ActionCalls { get; } = new();
        public List<string> VerbCalls { get; } = new();
        public bool IsRegisteredReturn { get; set; }

        public void RegisterAllBindings(IntPtr seatProxy) => RegisterCalls.Add(seatProxy);
        public bool IsBindingRegistered(IntPtr bindingProxy)
        {
            IsRegisteredCalls.Add(bindingProxy);
            return IsRegisteredReturn;
        }
        public void HandleKeyBindingAction(KeyBindingAction action) => ActionCalls.Add(action);
        public void RunCustomAction(string verb) => VerbCalls.Add(verb);
    }

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
        // Skip if /bin/true unavailable (non-Linux test runs).
        if (!System.IO.File.Exists("/bin/true"))
        {
            return;
        }
        var pl = new ProcessLauncher();
        Assert.True(pl.Start("/bin/true"));
    }

    // --- CustomActionRunner ---------------------------------------------

    [Fact]
    public void CustomActionRunner_NullCtorArg_Throws()
    {
        Assert.Throws<ArgumentNullException>(() => new CustomActionRunner(null!));
    }

    [Fact]
    public void CustomActionRunner_ForwardsVerbToCollab()
    {
        var collab = new FakeBindingsCollab();
        var runner = new CustomActionRunner(collab);
        runner.Run("spawn:foot");
        Assert.Single(collab.VerbCalls);
        Assert.Equal("spawn:foot", collab.VerbCalls[0]);
    }

    [Fact]
    public void CustomActionRunner_NullVerb_IsNoOp()
    {
        var collab = new FakeBindingsCollab();
        var runner = new CustomActionRunner(collab);
        runner.Run(null!);
        Assert.Empty(collab.VerbCalls);
    }

    // --- KeyBindingRouter -----------------------------------------------

    [Fact]
    public void KeyBindingRouter_NullCtorArg_Throws()
    {
        Assert.Throws<ArgumentNullException>(() => new KeyBindingRouter(null!));
    }

    [Fact]
    public void KeyBindingRouter_ForwardsActionToCollab()
    {
        var collab = new FakeBindingsCollab();
        var router = new KeyBindingRouter(collab);
        router.Handle(KeyBindingAction.CycleFocus);
        router.Handle(KeyBindingAction.SpawnTerminal);
        Assert.Equal(2, collab.ActionCalls.Count);
        Assert.Equal(KeyBindingAction.CycleFocus, collab.ActionCalls[0]);
        Assert.Equal(KeyBindingAction.SpawnTerminal, collab.ActionCalls[1]);
    }

    // --- KeyBindingRegistrar --------------------------------------------

    [Fact]
    public void KeyBindingRegistrar_NullCtorArg_Throws()
    {
        Assert.Throws<ArgumentNullException>(() => new KeyBindingRegistrar(null!));
    }

    [Fact]
    public void KeyBindingRegistrar_RegisterAllBindings_ForwardsSeat()
    {
        var collab = new FakeBindingsCollab();
        var reg = new KeyBindingRegistrar(collab);
        var seat = new IntPtr(0x1234);
        reg.RegisterAllBindings(seat);
        Assert.Single(collab.RegisterCalls);
        Assert.Equal(seat, collab.RegisterCalls[0]);
    }

    [Fact]
    public void KeyBindingRegistrar_IsRegistered_RoundTrips()
    {
        var collab = new FakeBindingsCollab { IsRegisteredReturn = true };
        var reg = new KeyBindingRegistrar(collab);
        var proxy = new IntPtr(0xDEAD);
        Assert.True(reg.IsRegistered(proxy));
        Assert.Equal(proxy, collab.IsRegisteredCalls[0]);

        collab.IsRegisteredReturn = false;
        Assert.False(reg.IsRegistered(proxy));
    }

    // --- Structural / decomposition guards ------------------------------

    [Fact]
    public void Stage7_BridgeInterface_DeclaresExactlyFourMembers()
    {
        var members = typeof(IKeyBindingsCollaborators).GetMembers(
            BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly);
        Assert.Equal(4, members.Length);
        var names = members.Select(m => m.Name).OrderBy(n => n).ToArray();
        Assert.Equal(
            new[] { "HandleKeyBindingAction", "IsBindingRegistered", "RegisterAllBindings", "RunCustomAction" },
            names);
    }

    [Fact]
    public void Stage7_GodClass_ImplementsBridge()
    {
        Assert.Contains(
            typeof(IKeyBindingsCollaborators),
            typeof(RiverWindowManagerClient).GetInterfaces());
    }

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
