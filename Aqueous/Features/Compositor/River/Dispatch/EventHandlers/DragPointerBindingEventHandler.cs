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

// drag-pointer binding event handler — extracted into its own partial-class file during the
// Phase 2 readability refactor (Step 4: split per-interface event handlers).
internal sealed unsafe partial class RiverWindowManagerClient
{
    private void OnDragPointerBindingEvent(uint opcode, WlArgument* args)
    {
        if (opcode == RiverProtocolOpcodes.Binding.Pressed)
        {
            // Find a seat that has a currently-hovered window and start a drag for it.
            foreach (var kvp in _seatHoveredWindow)
            {
                IntPtr seat = kvp.Key;
                IntPtr hovered = kvp.Value;
                if (hovered == IntPtr.Zero)
                {
                    continue;
                }

                if (!_windows.TryGetValue(hovered, out var w))
                {
                    continue;
                }

                _activeDragWindow = w;
                _activeDragSeat = seat;
                _dragStartX = w.X;
                _dragStartY = w.Y;
                Log($"super+click drag start on window 0x{hovered.ToString("x")} via seat 0x{seat.ToString("x")}");
                break;
            }
        }
        else if (opcode == RiverProtocolOpcodes.Binding.Released)
        {
            Log("super+click pointer binding released");
            // The matching op_release from the seat will set _dragFinished; nothing else to do here.
        }
    }
}
