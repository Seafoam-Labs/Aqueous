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
                // Stage 8 PR 8.1: routed through the managed IEventDispatcher
                // (LayerShellEventHandler). The native callback constructs the
                // WlEvent here; the handler decodes args via WlArgumentDecoder.
                self._eventDispatcher.Dispatch(
                    new Aqueous.Features.Compositor.River.Dispatch.WlEvent(
                        "river_layer_shell_v1", target, opcode, (IntPtr)a, 1));
            }
            else if (self._superKeyBinding != IntPtr.Zero && target == self._superKeyBinding)
            {
                self.OnSuperKeyBindingEvent(opcode, a);
            }
            else if (self._keyBindingRegistrar.IsRegistered(target))
            {
                self.OnKeyBindingEvent(target, opcode, a);
            }
            else if (target == self._dragPointerBinding)
            {
                self.OnDragPointerBindingEvent(target, opcode, a);
            }
            else if (self._dragResizePointerBinding != IntPtr.Zero && target == self._dragResizePointerBinding)
            {
                self.OnDragPointerBindingEvent(target, opcode, a);
            }
            else if (self._snapActivatorBindings.ContainsKey(target))
            {
                // Snap-activator pointer bindings reuse the same drag
                // dispatcher — the handler stamps _activeDragActivator
                // from the firing proxy and otherwise behaves identically
                // to the plain Super+LMB binding.
                self.OnDragPointerBindingEvent(target, opcode, a);
            }
            else if (self._windowRegistry.Entries.ContainsKey(target))
            {
                // PR 8.4 staged rollout — opcode allowlist bisect.
                // The managed WindowEventHandler is wired into
                // IEventDispatcher and currently delegates every
                // opcode back to the original partial OnWindowEvent
                // via IWindowHandlerCollaborators.HandleByPartial,
                // so behaviour is byte-for-byte equivalent regardless
                // of which branch fires. Expand the `routeManaged`
                // set one opcode at a time (with a manual River smoke
                // gate per opcode), mirroring the PR 8.3 SeatEvent
                // rollout pattern. Allowlist starts empty.
                bool routeManaged = opcode switch
                {
                    _ => false,
                };
                if (routeManaged)
                {
                    self._eventDispatcher.Dispatch(
                        new Aqueous.Features.Compositor.River.Dispatch.WlEvent(
                            "river_window_v1", target, opcode, (IntPtr)a, 4));
                }
                else
                {
                    self.OnWindowEvent(target, opcode, a);
                }
            }
            else if (self._outputRegistry.Entries.ContainsKey(target))
            {
                self._eventDispatcher.Dispatch(
                    new Aqueous.Features.Compositor.River.Dispatch.WlEvent(
                        "river_output_v1", target, opcode, (IntPtr)a, 2));
            }
            else if (self._seatRegistry.Entries.ContainsKey(target))
            {
                // PR 8.3 staged rollout — opcode allowlist bisect.
                // Safe, side-effect-light opcodes route through the new
                // managed SeatEventHandler; risky opcodes (focus-follow,
                // window/shell-surface interaction, drag delta/release)
                // stay on the original partial until proven equivalent.
                // Expand the `routeManaged` set one opcode at a time per
                // the rollout plan; see comments in Stage 8 PR 8.3.
                bool routeManaged = opcode switch
                {
                    RiverProtocolOpcodes.Seat.Removed => true,
                    RiverProtocolOpcodes.Seat.WlSeat => true,
                    RiverProtocolOpcodes.Seat.PointerLeave => true,
                    RiverProtocolOpcodes.Seat.PointerPosition => true,
                    _ => false,
                };
                if (routeManaged)
                {
                    self._eventDispatcher.Dispatch(
                        new Aqueous.Features.Compositor.River.Dispatch.WlEvent(
                            "river_seat_v1", target, opcode, (IntPtr)a, 2));
                }
                else
                {
                    self.OnSeatEvent(target, opcode, a);
                }
            }
            else if (self._screencopyService.TryDispatchFrameEvent(target, opcode, a))
            {
                // consumed by zwlr_screencopy_frame_v1
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
