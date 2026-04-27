using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Aqueous.Features.Compositor.River.Connection;
using Aqueous.Features.Input;
using Aqueous.Features.Layout;
using Aqueous.Features.State;
using Aqueous.Features.Tags;

namespace Aqueous.Features.Compositor.River;

// Super-key binding event handler — extracted into its own partial-class file during the
// Phase 2 readability refactor (Step 4: split per-interface event handlers).
internal sealed unsafe partial class RiverWindowManagerClient
{
    private void OnSuperKeyBindingEvent(uint opcode, WlArgument* args)
    {
        if (opcode == RiverProtocolOpcodes.Binding.Pressed)
        {
            Log("super key pressed, toggling Aqueous Start Menu via shell script/command");
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
                Log("failed to launch start menu dbus command: " + ex.Message);
            }
        }
        else if (opcode == RiverProtocolOpcodes.Binding.Released)
        {
            Log("super key released");
        }
    }
}
