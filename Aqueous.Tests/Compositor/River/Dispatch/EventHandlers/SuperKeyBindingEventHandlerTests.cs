using System;
using System.Linq;
using System.Reflection;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Dispatch.EventHandlers;

// PR 9.12 §2.13 Step 6: the dead RiverWindowManagerClient ctor arg
// (previously kept only to preserve this pin) has been removed. The
// handler now has zero god-class coupling — the only ctor parameter
// is an optional log sink. Per-opcode pass-through tests remain out
// of scope (the body P/Invokes dbus-send), so the surface contract
// is pinned by the structural guards below.
public unsafe class SuperKeyBindingEventHandlerTests
{
    [Fact]
    public void Handler_is_sealed_and_implements_IEventHandler()
    {
        var t = typeof(SuperKeyBindingEventHandler);
        Assert.True(t.IsSealed);
        Assert.Contains(typeof(IEventHandler), t.GetInterfaces());
    }

    // PR 9.12 §2.13 Step 10: negative god-class ctor-shape pin retired
    // with RiverWindowManagerClient itself.
    [Fact]
    public void Handler_ctor_takes_single_optional_log_sink()
    {
        var ctors = typeof(SuperKeyBindingEventHandler).GetConstructors();
        Assert.Single(ctors);
        Assert.Equal(1, ctors[0].GetParameters().Length);
    }
}
