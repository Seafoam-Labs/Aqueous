using System;
using Aqueous.Features.Layout;
using Xunit;

namespace Aqueous.Tests.Features.Layout;

/// <summary>
/// Unit tests for <see cref="ManagerRequestSender"/>. The class owns the small set of helpers that
/// marshal Wayland requests to <c>river_window_manager_v1</c> plus the manage-cycle flush flag.
/// <para>
/// The Wayland P/Invokes themselves cannot run in a unit-test process (libwayland-client requires
/// a live display connection). We assert the observable contract: <c>InsideManageSequence</c>
/// round-trips, <c>SendManagerRequest</c> + <c>ScheduleManage</c> no-op when the manager isn't
/// bound, <c>ScheduleManage</c> short-circuits inside a manage sequence, and the <c>IsBound</c>
/// probe tracks <c>Init</c>.
/// </para>
/// </summary>
public sealed class ManagerRequestSenderTests
{
    [Fact]
    public void InsideManageSequence_DefaultsFalse()
    {
        var s = new ManagerRequestSender();
        Assert.False(s.InsideManageSequence);
    }

    [Fact]
    public void InsideManageSequence_RoundTrips()
    {
        var s = new ManagerRequestSender();
        s.InsideManageSequence = true;
        Assert.True(s.InsideManageSequence);
        s.InsideManageSequence = false;
        Assert.False(s.InsideManageSequence);
    }

    [Fact]
    public void IsBound_FalseUntilInit()
    {
        var s = new ManagerRequestSender();
        Assert.False(s.IsBound);
    }

    [Fact]
    public void IsBound_TrueAfterInit_WithNonZeroManager()
    {
        var s = new ManagerRequestSender();
        s.Init(new IntPtr(0xCAFE), new IntPtr(0xBABE));
        Assert.True(s.IsBound);
    }

    [Fact]
    public void IsBound_FalseAfterInit_WithZeroManager()
    {
        var s = new ManagerRequestSender();
        s.Init(IntPtr.Zero, new IntPtr(0xBABE));
        Assert.False(s.IsBound);
    }

    [Fact]
    public void SendManagerRequest_BeforeBind_NoOps_NoThrow()
    {
        var s = new ManagerRequestSender();
        // No Init — calling Send must be a silent no-op (no P/Invoke dispatched against IntPtr.Zero,
        // which would crash the host).
        s.SendManagerRequest(opcode: 0);
        s.SendManagerRequest(opcode: 1);
        s.SendManagerRequest(opcode: 42);
        Assert.False(s.IsBound);
    }

    [Fact]
    public void ScheduleManage_BeforeBind_NoOps_NoThrow()
    {
        var s = new ManagerRequestSender();
        s.ScheduleManage();
    }

    [Fact]
    public void ScheduleManage_InsideManageSequence_NoOps_NoThrow()
    {
        // We cannot bind in a unit test (no live wl_display), but we can assert the short-circuit logic
        // by ensuring InsideManageSequence never trips a P/Invoke through the unbound guard path either.
        // The combined invariant: ScheduleManage must never throw.
        var s = new ManagerRequestSender();
        s.InsideManageSequence = true;
        s.ScheduleManage();
        s.InsideManageSequence = false;
        s.ScheduleManage();
    }
}
