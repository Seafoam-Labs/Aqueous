using System;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Dispatch.EventHandlers;

public sealed class DragPointerBindingEventHandlerTests
{
    // Retired IDragPointerBindingHandlerCollaborators; the handler now consumes
    // RiverWindowManagerClient directly. The god class can't be safely constructed in unit tests (it
    // opens a Wayland connection), so only the structural contract is exercised here. Behavioural
    // coverage moves to manual River smoke (drag move + resize + snap).

    [Fact]
    public void Ctor_throws_on_null_client()
    {
        Assert.Throws<ArgumentNullException>(
            () => new DragPointerBindingEventHandler(null!));
    }

    [Fact]
    public void Type_is_sealed_and_implements_IEventHandler()
    {
        var t = typeof(DragPointerBindingEventHandler);
        Assert.True(t.IsSealed);
        Assert.Contains(typeof(IEventHandler), t.GetInterfaces());
    }
}
