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

// Proxy dispatcher — the single [UnmanagedCallersOnly] entry point installed
// on every Wayland proxy this client owns. It self-locates the owning
// RiverWindowManagerClient via the GCHandle passed as the dispatcher's
// implementation pointer, then routes the event to the appropriate
// per-interface partial-class handler based on which proxy fired it.
//
// Extracted into its own partial-class file during the Phase 2 readability
// refactor (Step 4: split per-interface event handlers).
internal sealed unsafe partial class RiverWindowManagerClient
{
    [UnmanagedCallersOnly]
    private static int Dispatch(IntPtr implementation, IntPtr target, uint opcode, IntPtr msg, IntPtr args)
    {
        try
        {
            var gch = GCHandle.FromIntPtr(implementation);
            var self = gch.Target as RiverWindowManagerClient;
            if (self == null)
            {
                return 0;
            }

            var a = (WlArgument*)args;

            if (target == self._registry.Handle)
            {
                self._registry.HandleEvent(opcode, a);
            }
            else if (target == self._manager)
            {
                self.OnManagerEvent(opcode, a);
            }
            else if (target == self._layerShell)
            {
                self.OnLayerShellEvent(opcode, a);
            }
            else if (self._superKeyBinding != IntPtr.Zero && target == self._superKeyBinding)
            {
                self.OnSuperKeyBindingEvent(opcode, a);
            }
            else if (self._keyBindings.ContainsKey(target))
            {
                self.OnKeyBindingEvent(target, opcode, a);
            }
            else if (target == self._dragPointerBinding)
            {
                self.OnDragPointerBindingEvent(opcode, a);
            }
            else if (self._windows.ContainsKey(target))
            {
                self.OnWindowEvent(target, opcode, a);
            }
            else if (self._outputs.ContainsKey(target))
            {
                self.OnOutputEvent(target, opcode, a);
            }
            else if (self._seats.ContainsKey(target))
            {
                self.OnSeatEvent(target, opcode, a);
            }
            else
            {
                Log("unhandled dispatch: target=0x" + target.ToString("x") + " opcode=" + opcode);
            }
        }
        catch (Exception e)
        {
            // NEVER unwind into native dispatch.
            try
            {
                Log("dispatch exception: " + e.Message);
            }
            catch
            {
            }
        }

        return 0;
    }
}
