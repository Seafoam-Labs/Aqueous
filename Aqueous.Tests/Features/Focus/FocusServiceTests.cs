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
    public void FocusService_Ctor_DoesNotTake_RiverWindowManagerClient()
    {
        // PR 9.12 §2.13 Step 1: FocusService no longer depends on the
        // god class. State previously read from it now flows through
        // FocusedWindowTracker / PendingFocusStore / PrimarySeatTracker
        // DI singletons. Order: windowRegistry, outputRegistry,
        // seatRegistry, focusedWindow, pendingFocus, primarySeat,
        // managerRequestSender, layoutProposer.
        var ctor = typeof(FocusService).GetConstructors(
            System.Reflection.BindingFlags.Instance |
            System.Reflection.BindingFlags.NonPublic).Single();
        var p = ctor.GetParameters();
        Assert.Equal(8, p.Length);
        Assert.DoesNotContain(p, x => x.ParameterType == typeof(RiverWindowManagerClient));
        Assert.Equal(typeof(FocusedWindowTracker), p[3].ParameterType);
        Assert.Equal(typeof(PendingFocusStore), p[4].ParameterType);
        Assert.Equal(typeof(PrimarySeatTracker), p[5].ParameterType);
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
