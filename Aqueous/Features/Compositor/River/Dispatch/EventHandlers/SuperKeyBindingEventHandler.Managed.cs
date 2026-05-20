using System;
using Aqueous.Diagnostics;
namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
/// <summary>
/// Managed <see cref="IEventHandler"/> for the <c>river_super_key_binding_v1</c> proxy that fires
/// <c>pressed</c>/<c>released</c> opcodes (today triggers a dbus-send fire-and-forget to toggle
/// the Aqueous start menu). final cleanup: re-typed as a standalone handler — the
/// <c>OnSuperKeyBindingEvent</c> body. Logs flow through <see cref="RiverLog"/>. the dead
/// <c>RiverWindowManagerClient</c> ctor argument (. The handler now has zero class coupling.
/// </summary>
internal sealed unsafe class SuperKeyBindingEventHandler : IEventHandler
{
    private readonly Action<string>? _log;
    public SuperKeyBindingEventHandler(Action<string>? log = null)
    {
        _log = log;
    }
    public string InterfaceName => "river_super_key_binding_v1";
    public void Handle(WlEvent ev)
    {
        var opcode = ev.Opcode;
        if (opcode == RiverProtocolOpcodes.Binding.Pressed)
        {
            RiverLog.Write("super key pressed, toggling Aqueous Start Menu via shell script/command");
            try
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "dbus-send",
                    Arguments =
                        "--session --type=method_call --dest=org.Aqueous /org/Aqueous org.Aqueous.ToggleStartMenu",
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true
                });
            }
            catch (Exception ex)
            {
                RiverLog.Write("failed to launch start menu dbus command: " + ex.Message);
            }
        }
        else if (opcode == RiverProtocolOpcodes.Binding.Released)
        {
            RiverLog.Write("super key released");
        }
    }
}
