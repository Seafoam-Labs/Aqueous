using System;
using Aqueous.Features.Bindings;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Input;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// Routes <c>river_xkb_config_v1</c> events. The only event we act on is <c>xkb_keyboard</c>
/// (opcode <see cref="RiverProtocolOpcodes.XkbConfig.XkbKeyboard"/>): register the freshly-created
/// keyboard proxy with the dispatcher so its events flow to <c>XkbKeyboardEventHandler</c>, and
/// notify <see cref="XkbConfigApplier"/> so it can <c>set_keymap</c> on the device.
/// </summary>
internal sealed unsafe class XkbConfigEventHandler : IEventHandler
{
    private readonly XkbConfigApplier _applier;
    private readonly WaylandBindSiteState _bindSiteState;
    private readonly KeyBindingsRegistry _keyBindingsRegistry;
    private readonly Action<string>? _log;

    public XkbConfigEventHandler(
        XkbConfigApplier applier,
        WaylandBindSiteState bindSiteState,
        KeyBindingsRegistry keyBindingsRegistry,
        Action<string>? log = null)
    {
        _applier = applier ?? throw new ArgumentNullException(nameof(applier));
        _bindSiteState = bindSiteState ?? throw new ArgumentNullException(nameof(bindSiteState));
        _keyBindingsRegistry = keyBindingsRegistry ?? throw new ArgumentNullException(nameof(keyBindingsRegistry));
        _log = log;
    }

    public string InterfaceName => "river_xkb_config_v1";

    public void Handle(WlEvent ev)
    {
        if (ev.Opcode != RiverProtocolOpcodes.XkbConfig.XkbKeyboard)
        {
            return;
        }

        if (ev.ArgsPtr == IntPtr.Zero || ev.ArgCount < 1)
        {
            return;
        }

        var args = (WlArgument*)ev.ArgsPtr;
        // The new_id argument is delivered as an already-constructed proxy pointer in args[0].o.
        IntPtr keyboardProxy = args[0].o;
        if (keyboardProxy == IntPtr.Zero)
        {
            return;
        }

        _bindSiteState.TrackProxyInterface(keyboardProxy, "river_xkb_keyboard_v1");

        // Install the global native dispatcher so the keyboard proxy's events route through
        // EventDispatcher -> XkbKeyboardEventHandler (same pattern as LibinputConfigEventHandler).
        WaylandInterop.wl_proxy_add_dispatcher(
            keyboardProxy,
            (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&NativeCallbackEntry.Dispatch,
            _keyBindingsRegistry.SelfHandlePtr,
            IntPtr.Zero);

        _applier.OnKeyboardAdded(keyboardProxy);
        _log?.Invoke($"xkb keyboard announced: 0x{keyboardProxy.ToInt64():x}");
    }
}
