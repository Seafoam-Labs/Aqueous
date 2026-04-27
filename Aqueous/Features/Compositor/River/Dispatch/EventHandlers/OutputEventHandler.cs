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

// river_output_v1 event handler — extracted into its own partial-class file during the
// Phase 2 readability refactor (Step 4: split per-interface event handlers).
internal sealed unsafe partial class RiverWindowManagerClient
{
    private void OnOutputEvent(IntPtr proxy, uint opcode, WlArgument* args)
    {
        if (!_outputs.TryGetValue(proxy, out var o))
        {
            return;
        }
        // See RiverProtocolOpcodes.Output for the full event table.
        switch (opcode)
        {
            case RiverProtocolOpcodes.Output.Removed:
                Log($"output 0x{proxy.ToString("x")} removed");
                // Phase B1e Pass B: forward the removal to the window
                // state controller so it can demote any FS/Max windows
                // pinned to this output before _outputs forgets it.
                {
                    var goneOutputWindows = new List<WindowStateData>();
                    foreach (var sk in _windowStates)
                    {
                        if (sk.Value.PinnedOutput == proxy)
                        {
                            goneOutputWindows.Add(sk.Value);
                        }
                    }

                    _windowState.OnOutputRemoved(proxy, goneOutputWindows);
                    _outputFullscreen.TryRemove(proxy, out _);
                }
                _outputs.TryRemove(proxy, out _);
                // Detach windows from the gone output so the next
                // manage cycle re-adopts them onto a surviving one.
                foreach (var wkvp in _windows)
                {
                    if (wkvp.Value.Output == proxy)
                    {
                        wkvp.Value.Output = IntPtr.Zero;
                    }
                }

                break;
            case RiverProtocolOpcodes.Output.WlOutput:
                o.WlOutputName = args[0].u;
                Log($"output 0x{proxy.ToString("x")} wl_output_name={o.WlOutputName}");
                break;
            case RiverProtocolOpcodes.Output.Position:
                o.X = args[0].i;
                o.Y = args[1].i;
                Log($"output 0x{proxy.ToString("x")} position={o.X},{o.Y}");
                break;
            case RiverProtocolOpcodes.Output.Dimensions:
                o.Width = args[0].i;
                o.Height = args[1].i;
                Log($"output 0x{proxy.ToString("x")} dimensions={o.Width}x{o.Height}");
                break;
        }
    }
}
