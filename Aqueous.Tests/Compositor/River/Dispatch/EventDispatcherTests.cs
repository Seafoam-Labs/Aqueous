using System;
using System.Collections.Generic;
using Aqueous.Features.Compositor.River.Dispatch;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Dispatch;

/// <summary>
/// Unit tests for the managed event-dispatch seam: <see cref="EventDispatcher"/>, <see
/// cref="IEventHandler"/>, <see cref="WlEvent"/>. These tests intentionally cover only the
/// routing/guard behaviour of the dispatcher itself — per-interface handler tests will land
/// alongside each <c>IEventHandler</c> implementation as it is extracted out of
/// <c>RiverWindowManagerClient</c> in later PRs.
/// </summary>
public sealed class EventDispatcherTests
{
    private sealed class FakeHandler : IEventHandler
    {
        public FakeHandler(string interfaceName) => InterfaceName = interfaceName;
        public string InterfaceName { get; }
        public int Calls { get; private set; }
        public WlEvent? Last { get; private set; }
        public void Handle(WlEvent ev) { Calls++; Last = ev; }
    }

    [Fact]
    public void Routes_event_to_matching_handler_only()
    {
        var seat = new FakeHandler("wl_seat");
        var output = new FakeHandler("wl_output");
        var sut = new EventDispatcher(new IEventHandler[] { seat, output },
            NullLogger<EventDispatcher>.Instance);

        sut.Dispatch(new WlEvent("wl_output", opcode: 0));

        Assert.Equal(1, output.Calls);
        Assert.Equal(0, seat.Calls);
        Assert.NotNull(output.Last);
        Assert.Equal("wl_output", output.Last!.Value.InterfaceName);
        Assert.Equal(0u, output.Last!.Value.Opcode);
    }

    [Fact]
    public void Multiple_dispatches_go_to_the_right_handlers()
    {
        var seat = new FakeHandler("wl_seat");
        var output = new FakeHandler("wl_output");
        var sut = new EventDispatcher(new IEventHandler[] { seat, output },
            NullLogger<EventDispatcher>.Instance);

        sut.Dispatch(new WlEvent("wl_seat", 1));
        sut.Dispatch(new WlEvent("wl_seat", 2));
        sut.Dispatch(new WlEvent("wl_output", 0));

        Assert.Equal(2, seat.Calls);
        Assert.Equal(1, output.Calls);
    }

    [Fact]
    public void Unknown_interface_does_not_throw_and_invokes_no_handler()
    {
        var seat = new FakeHandler("wl_seat");
        var sut = new EventDispatcher(new IEventHandler[] { seat },
            NullLogger<EventDispatcher>.Instance);

        // Should be silently swallowed (logged at trace).
        sut.Dispatch(new WlEvent("zwlr_unknown_v1", opcode: 7));

        Assert.Equal(0, seat.Calls);
    }

    [Fact]
    public void Empty_handler_set_dispatches_as_noop()
    {
        var sut = new EventDispatcher(Array.Empty<IEventHandler>(),
            NullLogger<EventDispatcher>.Instance);

        sut.Dispatch(new WlEvent("wl_seat", 0));
        // No throw, no observable effect.
        Assert.Equal(0, sut.HandlerCount);
    }

    [Fact]
    public void Duplicate_interface_registration_throws_at_construction()
    {
        var a = new FakeHandler("wl_seat");
        var b = new FakeHandler("wl_seat");

        var ex = Assert.Throws<InvalidOperationException>(() =>
            new EventDispatcher(new IEventHandler[] { a, b },
                NullLogger<EventDispatcher>.Instance));

        Assert.Contains("wl_seat", ex.Message);
    }

    [Fact]
    public void Null_handler_in_list_throws_ArgumentException()
    {
        var list = new List<IEventHandler> { new FakeHandler("wl_seat"), null! };
        Assert.Throws<ArgumentException>(() =>
            new EventDispatcher(list, NullLogger<EventDispatcher>.Instance));
    }

    [Fact]
    public void Empty_interface_name_throws_ArgumentException()
    {
        Assert.Throws<ArgumentException>(() =>
            new EventDispatcher(new IEventHandler[] { new FakeHandler(string.Empty) },
                NullLogger<EventDispatcher>.Instance));
    }

    [Fact]
    public void HandlerCount_reflects_registered_handlers()
    {
        var sut = new EventDispatcher(new IEventHandler[]
        {
            new FakeHandler("wl_seat"),
            new FakeHandler("wl_output"),
            new FakeHandler("zriver_window_manager_v3"),
        }, NullLogger<EventDispatcher>.Instance);

        Assert.Equal(3, sut.HandlerCount);
    }

    [Fact]
    public void WlEvent_with_null_interface_name_throws()
    {
        Assert.Throws<ArgumentNullException>(() =>
            new WlEvent(null!, 0));
    }
}
