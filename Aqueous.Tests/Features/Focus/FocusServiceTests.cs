using System;
using System.Linq;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Focus;
using Xunit;

namespace Aqueous.Tests.Features.Focus;

/// <summary>
/// Stage 9 PR 9.6: <c>IFocusServiceCollaborators</c> bridge retired.
/// <c>FocusService</c> now consumes <see cref="RiverWindowManagerClient"/>
/// directly via pass-through accessors, which cannot be unit-tested in
/// isolation (no DI-safe way to construct the god class without a live
/// Wayland connection). Behaviour-level coverage migrates to integration
/// smoke tests against real River; this file retains structural guards
/// only — sealed-IFocusService contract, ctor signature, and the
/// reflection regression guard pinning the bridge interface deletion.
/// </summary>
public sealed class FocusServiceTests
{
    [Fact]
    public void FocusService_Implements_IFocusService()
    {
        Assert.Contains(typeof(IFocusService), typeof(FocusService).GetInterfaces());
        Assert.True(typeof(FocusService).IsSealed);
    }

    [Fact]
    public void FocusService_Ctor_Takes_RiverWindowManagerClient_Directly()
    {
        // PR 9.6: the bridge param was replaced with the typed god-class
        // ref. Find the internal ctor and assert its parameter type.
        var ctor = typeof(FocusService).GetConstructors(
            System.Reflection.BindingFlags.Instance |
            System.Reflection.BindingFlags.NonPublic).Single();
        var p = ctor.GetParameters();
        // Order: windowRegistry, outputRegistry, seatRegistry, river,
        //        managerRequestSender, layoutProposer.
        Assert.Equal(6, p.Length);
        Assert.Equal(typeof(RiverWindowManagerClient), p[3].ParameterType);
    }

    [Fact]
    public void IFocusServiceCollaborators_Type_Deleted()
    {
        // Regression guard: the bridge interface must no longer exist
        // in the Aqueous production assembly.
        var asm = typeof(RiverWindowManagerClient).Assembly;
        var t = asm.GetType("Aqueous.Features.Compositor.River.Focus.IFocusServiceCollaborators");
        Assert.Null(t);
    }

    [Fact]
    public void RiverWindowManagerClient_Does_Not_Implement_DeletedBridge()
    {
        // Defence in depth — if anyone resurrects the interface and
        // forgets to delete this guard, the type lookup above will
        // resurface it but the implementation list should still not
        // contain it.
        var asm = typeof(RiverWindowManagerClient).Assembly;
        var t = asm.GetType("Aqueous.Features.Compositor.River.Focus.IFocusServiceCollaborators");
        if (t == null) return; // already deleted (expected)
        Assert.DoesNotContain(t, typeof(RiverWindowManagerClient).GetInterfaces());
    }
}
