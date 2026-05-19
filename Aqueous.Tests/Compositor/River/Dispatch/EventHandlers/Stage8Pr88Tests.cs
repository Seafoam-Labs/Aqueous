using System;
using System.Linq;
using System.Reflection;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Dispatch;
using Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
using Aqueous.Features.Screencopy;
using Xunit;

namespace Aqueous.Tests.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// PR 8.8 — regression guards for the native callback rewrite.
///
/// After PR 8.8 the prior <c>ProxyDispatcher.cs</c> is deleted and
/// replaced by <c>NativeDispatchBridge.cs</c> which performs
/// interface-name-based dispatch through <see cref="IEventDispatcher"/>.
/// Three new <see cref="IEventHandler"/> implementations cover the
/// formerly proxy-pointer-keyed branches: <see cref="RegistryEventHandler"/>,
/// <see cref="KeyBindingEventHandler"/>, and <see cref="ScreencopyFrameHandler"/>.
/// </summary>
public class Stage8Pr88Tests
{
    // ----- new IEventHandler impls --------------------------------------

    [Fact]
    public void RegistryEventHandler_implements_IEventHandler_with_wl_registry()
    {
        Assert.True(typeof(IEventHandler).IsAssignableFrom(typeof(RegistryEventHandler)));
        Assert.True(typeof(RegistryEventHandler).IsSealed);

        var h = new RegistryEventHandler(new Aqueous.Features.Compositor.River.Connection.RegistryBinder());
        Assert.Equal("wl_registry", h.InterfaceName);
    }

    [Fact]
    public void KeyBindingEventHandler_implements_IEventHandler_with_river_xkb_binding_v1()
    {
        Assert.True(typeof(IEventHandler).IsAssignableFrom(typeof(KeyBindingEventHandler)));
        Assert.True(typeof(KeyBindingEventHandler).IsSealed);

        var h = new KeyBindingEventHandler(new FakeKeyBinding());
        Assert.Equal("river_xkb_binding_v1", h.InterfaceName);
    }

    [Fact]
    public void ScreencopyFrameHandler_implements_IEventHandler_with_zwlr_screencopy_frame_v1()
    {
        Assert.True(typeof(IEventHandler).IsAssignableFrom(typeof(ScreencopyFrameHandler)));
        Assert.True(typeof(ScreencopyFrameHandler).IsSealed);

        var h = new ScreencopyFrameHandler(new FakeScreencopy());
        Assert.Equal("zwlr_screencopy_frame_v1", h.InterfaceName);
    }

    [Fact]
    public void RegistryEventHandler_ctor_null_guards()
    {
        Assert.Throws<ArgumentNullException>(() => new RegistryEventHandler(null!));
    }

    [Fact]
    public void KeyBindingEventHandler_ctor_null_guards()
    {
        Assert.Throws<ArgumentNullException>(() => new KeyBindingEventHandler(null!));
    }

    [Fact]
    public void ScreencopyFrameHandler_ctor_null_guards()
    {
        Assert.Throws<ArgumentNullException>(() => new ScreencopyFrameHandler(null!));
    }

    // ----- pass-through forwarding via bridges --------------------------

    [Fact]
    public unsafe void RegistryEventHandler_forwards_to_RegistryBinder()
    {
        // PR 9.3 Stage 9: bridge retired; handler consumes RegistryBinder
        // directly. Subscribe to Removed (opcode 1 = global_remove) to
        // observe routing.
        var binder = new Aqueous.Features.Compositor.River.Connection.RegistryBinder();
        uint observed = 0;
        binder.Removed += name => observed = name;
        var h = new RegistryEventHandler(binder);
        var args = stackalloc WlArgument[1];
        args[0].u = 42u;
        h.Handle(new WlEvent("wl_registry", new IntPtr(0xAA), Aqueous.Features.Compositor.River.RiverProtocolOpcodes.Registry.GlobalRemove, (IntPtr)args, 1));
        Assert.Equal(42u, observed);
    }

    [Fact]
    public unsafe void RegistryEventHandler_zero_argsptr_is_skipped()
    {
        var binder = new Aqueous.Features.Compositor.River.Connection.RegistryBinder();
        uint observed = 0;
        binder.Removed += name => observed = name;
        var h = new RegistryEventHandler(binder);
        h.Handle(new WlEvent("wl_registry", new IntPtr(0xAA), Aqueous.Features.Compositor.River.RiverProtocolOpcodes.Registry.GlobalRemove, IntPtr.Zero, 0));
        Assert.Equal(0u, observed);
    }

    [Fact]
    public unsafe void KeyBindingEventHandler_forwards_to_bridge()
    {
        var bridge = new FakeKeyBinding();
        var h = new KeyBindingEventHandler(bridge);
        var args = stackalloc WlArgument[1];
        h.Handle(new WlEvent("river_xkb_binding_v1", new IntPtr(0xBB), 2, (IntPtr)args, 1));
        Assert.Equal(1, bridge.Calls);
        Assert.Equal((uint)2, bridge.LastOpcode);
        Assert.Equal(new IntPtr(0xBB), bridge.LastTarget);
    }

    [Fact]
    public unsafe void KeyBindingEventHandler_zero_target_is_skipped()
    {
        var bridge = new FakeKeyBinding();
        var h = new KeyBindingEventHandler(bridge);
        h.Handle(new WlEvent("river_xkb_binding_v1", IntPtr.Zero, 2, IntPtr.Zero, 0));
        Assert.Equal(0, bridge.Calls);
    }

    [Fact]
    public unsafe void ScreencopyFrameHandler_forwards_to_service()
    {
        var svc = new FakeScreencopy();
        var h = new ScreencopyFrameHandler(svc);
        var args = stackalloc WlArgument[1];
        h.Handle(new WlEvent("zwlr_screencopy_frame_v1", new IntPtr(0xCC), 3, (IntPtr)args, 1));
        Assert.Equal(1, svc.DispatchCalls);
        Assert.Equal((uint)3, svc.LastOpcode);
        Assert.Equal(new IntPtr(0xCC), svc.LastFrame);
    }

    [Fact]
    public unsafe void ScreencopyFrameHandler_zero_target_is_skipped()
    {
        var svc = new FakeScreencopy();
        var h = new ScreencopyFrameHandler(svc);
        h.Handle(new WlEvent("zwlr_screencopy_frame_v1", IntPtr.Zero, 3, IntPtr.Zero, 0));
        Assert.Equal(0, svc.DispatchCalls);
    }

    // ----- regression guards: file rename + ProxyDispatcher gone --------

    [Fact]
    public void ProxyDispatcher_type_no_longer_exists()
    {
        // The Stage-0/8 plan calls for deletion of the historical
        // ProxyDispatcher entry point. After PR 8.8 it must not be
        // present as a top-level type in the assembly.
        var asm = typeof(IEventHandler).Assembly;
        var types = asm.GetTypes().Select(t => t.FullName).ToArray();
        Assert.DoesNotContain(
            "Aqueous.Features.Compositor.River.ProxyDispatcher",
            types);
    }

    [Fact]
    public void RiverWindowManagerClient_partial_has_no_member_named_ProxyDispatcher()
    {
        // Member name should not survive on the god class either.
        var t = typeof(IEventHandler).Assembly
            .GetType("Aqueous.Features.Compositor.River.RiverWindowManagerClient");
        Assert.NotNull(t);
        var members = t!.GetMembers(BindingFlags.Public | BindingFlags.NonPublic
                                  | BindingFlags.Instance | BindingFlags.Static
                                  | BindingFlags.DeclaredOnly);
        Assert.DoesNotContain(members, m => m.Name == "ProxyDispatcher");
    }

    // ----- bridge shape guards ------------------------------------------

    // PR 9.3 Stage 9 retired IRegistryHandlerCollaborators; see
    // Stage9Pr93Tests for the replacement regression guards.

    [Fact]
    public void IKeyBindingHandlerCollaborators_has_only_HandleKeyBindingEvent()
    {
        var t = typeof(IEventHandler).Assembly
            .GetType("Aqueous.Features.Compositor.River.Dispatch.EventHandlers.IKeyBindingHandlerCollaborators");
        Assert.NotNull(t);
        Assert.True(t!.IsInterface);
        var methods = t.GetMethods();
        Assert.Single(methods);
        Assert.Equal("HandleKeyBindingEvent", methods[0].Name);
    }

    [Fact]
    public void ScreencopyFrameHandler_has_no_companion_bridge_interface()
    {
        // Per the plan, the screencopy handler is bridge-less — it
        // depends only on IScreencopyService.
        var t = typeof(IEventHandler).Assembly
            .GetType("Aqueous.Features.Compositor.River.Dispatch.EventHandlers.IScreencopyFrameHandlerCollaborators");
        Assert.Null(t);
    }

    [Fact]
    public void RiverWindowManagerClient_implements_new_bridges()
    {
        var t = typeof(IEventHandler).Assembly
            .GetType("Aqueous.Features.Compositor.River.RiverWindowManagerClient");
        Assert.NotNull(t);
        var ifaces = t!.GetInterfaces().Select(i => i.FullName).ToArray();
        // PR 9.3 Stage 9 retired IRegistryHandlerCollaborators (assertion
        // dropped); the remaining bridge guards continue to hold.
        Assert.Contains(
            "Aqueous.Features.Compositor.River.Dispatch.EventHandlers.IKeyBindingHandlerCollaborators",
            ifaces);
    }

    // ----- integration: dispatch a synthetic event through real EventDispatcher

    [Fact]
    public unsafe void IEventDispatcher_routes_three_new_handlers_by_interface_name()
    {
        var binder = new Aqueous.Features.Compositor.River.Connection.RegistryBinder();
        uint regCalls = 0;
        binder.Removed += _ => regCalls++;
        var key = new FakeKeyBinding();
        var svc = new FakeScreencopy();
        var ed = new EventDispatcher(new IEventHandler[]
        {
            new RegistryEventHandler(binder),
            new KeyBindingEventHandler(key),
            new ScreencopyFrameHandler(svc),
        });

        var args = stackalloc WlArgument[1];
        args[0].u = 7u;

        ed.Dispatch(new WlEvent("wl_registry", new IntPtr(0x11), Aqueous.Features.Compositor.River.RiverProtocolOpcodes.Registry.GlobalRemove, (IntPtr)args, 1));
        ed.Dispatch(new WlEvent("river_xkb_binding_v1", new IntPtr(0x22), 0, (IntPtr)args, 1));
        ed.Dispatch(new WlEvent("zwlr_screencopy_frame_v1", new IntPtr(0x33), 0, (IntPtr)args, 1));

        Assert.Equal(1u, regCalls);
        Assert.Equal(1, key.Calls);
        Assert.Equal(1, svc.DispatchCalls);
    }

    // -------------------- fakes -----------------------------------------

    // PR 9.3 Stage 9: FakeRegistry retired with IRegistryHandlerCollaborators;
    // tests now drive RegistryEventHandler against a real RegistryBinder.

    private sealed class FakeKeyBinding : IKeyBindingHandlerCollaborators
    {
        public int Calls;
        public uint LastOpcode;
        public IntPtr LastTarget;
        public unsafe void HandleKeyBindingEvent(IntPtr target, uint opcode, WlArgument* args)
        {
            Calls++;
            LastOpcode = opcode;
            LastTarget = target;
        }
    }

    private sealed class FakeScreencopy : IScreencopyService
    {
        public int DispatchCalls;
        public uint LastOpcode;
        public IntPtr LastFrame;
        public bool IsReady => false;
        public System.Threading.Tasks.Task<ScreencopyResult>? CaptureOutputAsync(IntPtr output, bool overlayCursor = false) => null;
        public unsafe bool TryDispatchFrameEvent(IntPtr frame, uint opcode, WlArgument* args)
        {
            DispatchCalls++;
            LastOpcode = opcode;
            LastFrame = frame;
            return true;
        }
        public void TryActivate(IntPtr screencopyManager, uint version, IntPtr shm, IntPtr selfHandle, IntPtr dispatcher) { }
    }
}
