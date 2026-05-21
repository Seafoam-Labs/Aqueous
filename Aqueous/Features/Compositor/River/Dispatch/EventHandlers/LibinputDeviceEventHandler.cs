using System;
using Aqueous.Features.Input;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// Routes <c>river_libinput_device_v1</c> events. The compositor emits 50+ <c>*_support</c>/<c>
/// *_default</c>/<c>*_current</c> events per device; this handler only acts on the three that
/// <see cref="LibinputConfigApplier"/> needs:
/// <list type="bullet">
/// <item><c>removed</c> (opcode <see cref="RiverProtocolOpcodes.LibinputDeviceEvent.Removed"/>) → drop bookkeeping.</item>
/// <item><c>tap_support</c> (opcode <see cref="RiverProtocolOpcodes.LibinputDeviceEvent.TapSupport"/>) → classify as touchpad when <c>finger_count &gt; 0</c>.</item>
/// <item><c>done</c> (opcode <see cref="RiverProtocolOpcodes.LibinputDeviceEvent.Done"/>) → trigger first apply.</item>
/// </list>
/// All other events are intentionally dropped — we don't need their values to push config, and
/// libwayland's dispatcher still consumes the wire bytes via the message-table declared in
/// <see cref="WlInterfaces"/>.
/// </summary>
internal sealed unsafe class LibinputDeviceEventHandler : IEventHandler
{
    private readonly LibinputConfigApplier _applier;
    private readonly Action<string>? _log;

    public LibinputDeviceEventHandler(LibinputConfigApplier applier, Action<string>? log = null)
    {
        _applier = applier ?? throw new ArgumentNullException(nameof(applier));
        _log = log;
    }

    public string InterfaceName => "river_libinput_device_v1";

    public void Handle(WlEvent ev)
    {
        var args = (WlArgument*)ev.ArgsPtr;
        switch (ev.Opcode)
        {
            case RiverProtocolOpcodes.LibinputDeviceEvent.Removed:
                _applier.OnDeviceRemoved(ev.Target);
                _log?.Invoke($"libinput device removed: 0x{ev.Target.ToInt64():x}");
                break;
            case RiverProtocolOpcodes.LibinputDeviceEvent.TapSupport:
                if (ev.ArgsPtr != IntPtr.Zero && ev.ArgCount >= 1)
                {
                    _applier.OnTapSupport(ev.Target, args[0].i);
                }
                break;
            case RiverProtocolOpcodes.LibinputDeviceEvent.Done:
                _applier.OnDeviceDone(ev.Target);
                break;
        }
    }
}
