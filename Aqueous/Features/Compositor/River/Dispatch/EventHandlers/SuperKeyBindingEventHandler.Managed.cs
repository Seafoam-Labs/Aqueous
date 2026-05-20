using System;
using Aqueous.Diagnostics;
namespace Aqueous.Features.Compositor.River.Dispatch.EventHandlers;
/// <summary>
/// Managed <see cref="IEventHandler"/> for the
/// <c>river_super_key_binding_v1</c> proxy that fires
/// <c>pressed</c>/<c>released</c> opcodes (today triggers a dbus-send
/// fire-and-forget to toggle the Aqueous start menu).
///
/// PR 9.12 §2.13 final cleanup: re-typed as a standalone handler — the
/// <c>OnSuperKeyBindingEvent</c> body previously living in a
/// <c>partial class RiverWindowManagerClient</c> file is now inline
/// here. Logs flow through <see cref="RiverLog"/>; client ref is no
/// longer needed by this handler (kept on ctor as an unused parameter
/// only to preserve the DI ctor shape pinned by
/// <c>Stage9Pr99Tests</c> until that pin is updated alongside god-class
/// deletion).
/// </summary>
internal sealed unsafe class SuperKeyBindingEventHandler : IEventHandler
{
    private readonly RiverWindowManagerClient _client;
    private readonly Action<string>? _log;
    public SuperKeyBindingEventHandler(
        RiverWindowManagerClient client,
        Action<string>? log = null)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
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
