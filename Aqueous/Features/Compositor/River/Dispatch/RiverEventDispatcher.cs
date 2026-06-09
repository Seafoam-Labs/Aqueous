using System;
using Aqueous.Diagnostics;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Screencopy;
namespace Aqueous.Features.Compositor.River.Dispatch;

/// <summary>
/// Final demolition. The dispatcher no longer references the retired
/// <c>RiverWindowManagerClient</c> god class. Its three collaborators (<see
/// cref="WaylandBindSiteState"/>, <see cref="IEventDispatcher"/>, <see
/// cref="IScreencopyService"/>) are now injected directly.
/// </summary>
internal sealed unsafe class RiverEventDispatcher
{
    private readonly WaylandBindSiteState _bindSiteState;
    private readonly IEventDispatcher _eventDispatcher;
    private readonly IScreencopyService _screencopyService;

    internal RiverEventDispatcher(
        WaylandBindSiteState bindSiteState,
        IEventDispatcher eventDispatcher,
        IScreencopyService screencopyService)
    {
        _bindSiteState = bindSiteState ?? throw new ArgumentNullException(nameof(bindSiteState));
        _eventDispatcher = eventDispatcher ?? throw new ArgumentNullException(nameof(eventDispatcher));
        _screencopyService = screencopyService ?? throw new ArgumentNullException(nameof(screencopyService));
    }

    /// <summary>
    /// Owns the body. The native entry rehydrates a <see cref="NativeCallbackContext"/> from the
    /// GCHandle and calls into this dispatcher.
    /// </summary>
    internal int DispatchNative(IntPtr target, uint opcode, IntPtr args)
    {
        var a = (WlArgument*)args;

        var iface = _bindSiteState.TryGetProxyInterface(target);
        if (iface is not null)
        {
            RiverLog.Write("DISPATCH iface=" + iface + " target=0x" + target.ToString("x") + " opcode=" + opcode);
            int argCount = iface switch
            {
                "river_window_manager_v1" => 5,
                "river_window_v1" => 5,
                "river_output_v1" => 2,
                "river_seat_v1" => 2,
                "river_layer_shell_v1" => 1,
                "river_super_key_binding_v1" => 0,
                "river_pointer_binding_v1" => 0,
                "river_xkb_binding_v1" => 0,
                "ext_workspace_manager_v1" => 1,
                "ext_workspace_group_handle_v1" => 1,
                "ext_workspace_handle_v1" => 1,
                "wl_registry" => 4,
                // river_libinput_config_v1::libinput_device(new_id<device>): 1 arg.
                // The only other event we handle (finished) has 0 args.
                "river_libinput_config_v1" => 1,
                // river_libinput_device_v1 events vary 0..1 args; we only inspect args[0] in
                // the 1-arg cases (tap_support). Sizing at 1 is safe.
                "river_libinput_device_v1" => 1,
                _ => 4,
            };
            _eventDispatcher.Dispatch(
                new WlEvent(iface, target, opcode, (IntPtr)a, argCount));
            return 0;
        }

        if (_screencopyService.TryDispatchFrameEvent(target, opcode, a))
        {
            return 0;
        }

        RiverLog.Write("DISPATCH-MISS target=0x" + target.ToString("x") + " opcode=" + opcode);
        return 0;
    }
}
