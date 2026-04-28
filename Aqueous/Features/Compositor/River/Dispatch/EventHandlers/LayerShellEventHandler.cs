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

// river_layer_shell_v1 event handler — extracted into its own partial-class file during the
// Phase 2 readability refactor (Step 4: split per-interface event handlers).
internal sealed unsafe partial class RiverWindowManagerClient
{
    private void OnLayerShellEvent(uint opcode, WlArgument* args)
    {
        if (opcode == RiverProtocolOpcodes.LayerShell.LayerSurface)
        {
            IntPtr layerSurface = args[0].o;
            if (layerSurface != IntPtr.Zero)
            {
                IntPtr node = WaylandInterop.wl_proxy_marshal_flags(
                    layerSurface, 0, (IntPtr)WlInterfaces.RiverNode, 1, 0,
                    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                if (node != IntPtr.Zero)
                {
                    WaylandInterop.wl_proxy_marshal_flags(node, 2, IntPtr.Zero, 1, 0,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                    Log("mapped layer_surface to top");
                }
            }
        }
    }
}
