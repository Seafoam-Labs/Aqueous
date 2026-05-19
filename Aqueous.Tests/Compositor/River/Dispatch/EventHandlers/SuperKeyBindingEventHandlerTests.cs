using System;
using System.Linq;
using System.Reflection;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Dispatch.EventHandlers;

// PR 9.4 Stage 9: the ISuperKeyBindingHandlerCollaborators bridge was
// retired and SuperKeyBindingEventHandler now consumes
// RiverWindowManagerClient directly (same pattern PR 9.3 used for
// RegistryEventHandler). Construction of the god class is not safe in
// a unit test context (real Wayland connection), so the per-opcode
// pass-through tests were dropped; the surface contract is still
// pinned by the structural guards below + the deeper PR 9.4
// regression guards.
public unsafe class SuperKeyBindingEventHandlerTests
{
    [Fact]
    public void Ctor_rejects_null_client()
    {
        Assert.Throws<ArgumentNullException>(() => new SuperKeyBindingEventHandler(null!));
    }

    [Fact]
    public void Handler_is_sealed_and_implements_IEventHandler()
    {
        var t = typeof(SuperKeyBindingEventHandler);
        Assert.True(t.IsSealed);
        Assert.Contains(typeof(IEventHandler), t.GetInterfaces());
    }

    [Fact]
    public void Handler_ctor_takes_god_class_directly_not_bridge()
    {
        var ctors = typeof(SuperKeyBindingEventHandler).GetConstructors();
        Assert.Single(ctors);
        var ps = ctors[0].GetParameters();
        Assert.Equal(typeof(RiverWindowManagerClient), ps[0].ParameterType);
    }
}
