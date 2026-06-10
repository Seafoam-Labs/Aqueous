using System;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Input;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// Routes <c>river_xkb_keyboard_v1</c> events. The compositor emits <c>input_device</c>,
/// <c>layout</c>, <c>done</c>, capslock/numlock state and <c>removed</c>; this handler only acts on
/// <c>removed</c> (opcode <see cref="RiverProtocolOpcodes.XkbKeyboard.Removed"/>) to drop the device
/// from <see cref="XkbConfigApplier"/>'s bookkeeping and untrack its proxy. All other events are
/// consumed by libwayland via the populated message table and intentionally ignored.
/// </summary>
internal sealed class XkbKeyboardEventHandler : IEventHandler
{
    private readonly XkbConfigApplier _applier;
    private readonly WaylandBindSiteState _bindSiteState;

    public XkbKeyboardEventHandler(XkbConfigApplier applier, WaylandBindSiteState bindSiteState)
    {
        _applier = applier ?? throw new ArgumentNullException(nameof(applier));
        _bindSiteState = bindSiteState ?? throw new ArgumentNullException(nameof(bindSiteState));
    }

    public string InterfaceName => "river_xkb_keyboard_v1";

    public void Handle(WlEvent ev)
    {
        if (ev.Opcode == RiverProtocolOpcodes.XkbKeyboard.Removed)
        {
            _applier.OnKeyboardRemoved(ev.Target);
            _bindSiteState.UntrackProxyInterface(ev.Target);
        }
    }
}
