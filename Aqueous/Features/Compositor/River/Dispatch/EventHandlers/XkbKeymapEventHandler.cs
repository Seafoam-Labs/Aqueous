using System;
using System.Runtime.InteropServices;
using Aqueous.Features.Input;

namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;

/// <summary>
/// Routes <c>river_xkb_keymap_v1</c> events to <see cref="XkbConfigApplier"/>:
/// <list type="bullet">
/// <item><c>success</c> (opcode <see cref="RiverProtocolOpcodes.XkbKeymap.Success"/>) → promote the
/// keymap and push it to every keyboard.</item>
/// <item><c>failure</c> (opcode <see cref="RiverProtocolOpcodes.XkbKeymap.Failure"/>) → log the
/// compositor's error message and drop the pending keymap.</item>
/// </list>
/// </summary>
internal sealed unsafe class XkbKeymapEventHandler : IEventHandler
{
    private readonly XkbConfigApplier _applier;

    public XkbKeymapEventHandler(XkbConfigApplier applier)
    {
        _applier = applier ?? throw new ArgumentNullException(nameof(applier));
    }

    public string InterfaceName => "river_xkb_keymap_v1";

    public void Handle(WlEvent ev)
    {
        switch (ev.Opcode)
        {
            case RiverProtocolOpcodes.XkbKeymap.Success:
                _applier.OnKeymapSuccess(ev.Target);
                break;
            case RiverProtocolOpcodes.XkbKeymap.Failure:
                string? msg = null;
                if (ev.ArgsPtr != IntPtr.Zero && ev.ArgCount >= 1)
                {
                    var args = (WlArgument*)ev.ArgsPtr;
                    if (args[0].s != IntPtr.Zero)
                    {
                        msg = Marshal.PtrToStringUTF8(args[0].s);
                    }
                }
                _applier.OnKeymapFailure(ev.Target, msg);
                break;
        }
    }
}
