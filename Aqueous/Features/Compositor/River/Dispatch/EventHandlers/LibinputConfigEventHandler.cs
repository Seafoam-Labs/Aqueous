using System;
using Aqueous.Features.Bindings;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Input;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// Routes <c>river_libinput_config_v1</c> events. The only event we care about is
/// <c>libinput_device</c> (opcode <see cref="RiverProtocolOpcodes.LibinputConfig.LibinputDevice"/>):
/// register the freshly-created device proxy with the dispatcher so its events flow to
/// <c>LibinputDeviceEventHandler</c>, and notify <see cref="LibinputConfigApplier"/> so it can apply
/// <c>wm.toml</c> settings on the device's <c>done</c> event.
/// </summary>
internal sealed unsafe class LibinputConfigEventHandler : IEventHandler
{
    private readonly LibinputConfigApplier _applier;
    private readonly WaylandBindSiteState _bindSiteState;
    private readonly KeyBindingsRegistry _keyBindingsRegistry;
    private readonly Action<string>? _log;

    public LibinputConfigEventHandler(
        LibinputConfigApplier applier,
        WaylandBindSiteState bindSiteState,
        KeyBindingsRegistry keyBindingsRegistry,
        Action<string>? log = null)
    {
        _applier = applier ?? throw new ArgumentNullException(nameof(applier));
        _bindSiteState = bindSiteState ?? throw new ArgumentNullException(nameof(bindSiteState));
        _keyBindingsRegistry = keyBindingsRegistry ?? throw new ArgumentNullException(nameof(keyBindingsRegistry));
        _log = log;
    }

    public string InterfaceName => "river_libinput_config_v1";

    public void Handle(WlEvent ev)
    {
        if (ev.Opcode != RiverProtocolOpcodes.LibinputConfig.LibinputDevice)
        {
            return;
        }

        if (ev.ArgsPtr == IntPtr.Zero || ev.ArgCount < 1)
        {
            return;
        }

        var args = (WlArgument*)ev.ArgsPtr;
        // The new_id argument is delivered as an already-constructed proxy pointer in args[0].o
        // (libwayland-client's dispatcher resolves the new id and hands us the proxy directly).
        IntPtr devProxy = args[0].o;
        if (devProxy == IntPtr.Zero)
        {
            return;
        }

        _bindSiteState.TrackProxyInterface(devProxy, "river_libinput_device_v1");
        _applier.OnDeviceAdded(devProxy);

        // Install the global native dispatcher on the new device proxy so its events route through
        // EventDispatcher -> LibinputDeviceEventHandler. Same pattern as ManagerEventService uses
        // for window/output/seat proxies created from the manager.
        WaylandInterop.wl_proxy_add_dispatcher(
            devProxy,
            (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&NativeCallbackEntry.Dispatch,
            _keyBindingsRegistry.SelfHandlePtr,
            IntPtr.Zero);

        _log?.Invoke($"libinput device announced: 0x{devProxy.ToInt64():x}");
    }
}
