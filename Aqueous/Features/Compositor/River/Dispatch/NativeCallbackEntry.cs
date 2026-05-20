using System;
using System.Runtime.InteropServices;

namespace Aqueous.Features.Compositor.River.Dispatch;

/// <summary>
/// Stage 9 PR 9.11 — the <see cref="UnmanagedCallersOnlyAttribute"/>
/// entry function called by libwayland for every event dispatched to a
/// proxy whose dispatcher we own. Previously lived as a partial-class
/// static in <c>NativeDispatchBridge.cs</c>; lifted here so the god class
/// no longer owns the native callback.
///
/// <para>
/// Behaviour is byte-for-byte equivalent to the prior partial: the
/// GCHandle anchor (<see cref="RiverWindowManagerClient._selfHandle"/>)
/// is unchanged for now — PR 9.11 keeps the existing anchor object so
/// the lift is purely a relocation. A future PR (9.12 / cross-cutting
/// concerns: "GCHandle / native callback lifetime") may re-pin the
/// handle to a dedicated <c>NativeCallbackContext</c> owned by
/// <c>RiverCompositorHost</c>.
/// </para>
///
/// <para>
/// Routing: interface-name lookup against the Stage-0 proxy → interface
/// map, then dispatch via <see cref="IEventDispatcher"/>. Screencopy
/// frame proxies (owned by <c>WlrScreencopyClient</c>, not tracked in
/// the map) keep their dedicated fallback through
/// <c>IScreencopyService.TryDispatchFrameEvent</c>.
/// </para>
/// </summary>
internal static unsafe class NativeCallbackEntry
{
    [UnmanagedCallersOnly]
    internal static int Dispatch(IntPtr implementation, IntPtr target, uint opcode, IntPtr msg, IntPtr args)
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

            // Primary path: interface-name lookup against the
            // Stage-0 _proxyInterface map. Every proxy that this
            // client binds (or receives in a new_id slot) is tracked
            // at bind/declare time. ManagerEventHandler tracks
            // per-window/output/seat/pointer-binding proxies as
            // they appear; KeyBindingRegistrar tracks per-key
            // xkb-binding proxies as they are declared.
            //
            // Per-interface max ArgCount — derived from the protocol
            // XMLs. Several handlers (Seat / Output / LayerShell) use
            // `ev.ArgCount < N` as an early-return guard against
            // malformed events; the previous proxy-pointer dispatcher
            // passed conservative literals (2, 4) per-branch. Mirror
            // those exactly here so the rewrite is byte-for-byte
            // equivalent. Interfaces not enumerated below default to
            // the prior dispatcher's literal (which for the screencopy
            // fallback was unset / unused).
            var iface = self.TryGetProxyInterface(target);
            if (iface is not null)
            {
                // DIAG: prove which interface each event is routed as.
                // High-volume; gated to Debug level via Log classifier.
                RiverWindowManagerClient.Log("DISPATCH iface=" + iface + " target=0x" + target.ToString("x") + " opcode=" + opcode);
                int argCount = iface switch
                {
                    "river_window_manager_v1" => 4,
                    "river_window_v1" => 4,
                    "river_output_v1" => 2,
                    "river_seat_v1" => 2,
                    "river_layer_shell_v1" => 1,
                    "river_super_key_binding_v1" => 0,
                    "river_pointer_binding_v1" => 0,
                    "river_xkb_binding_v1" => 0,
                    "wl_registry" => 4,
                    _ => 4,
                };
                self.EventDispatcher.Dispatch(
                    new WlEvent(iface, target, opcode, (IntPtr)a, argCount));
                return 0;
            }

            // Fallback: screencopy frame proxies are owned by
            // WlrScreencopyClient and not tracked in _proxyInterface
            // (they live in the client's own per-frame state). The
            // ScreencopyFrameHandler IEventHandler is registered for
            // when frames eventually graduate into _proxyInterface,
            // but until then we keep the direct service call.
            if (self.ScreencopyService.TryDispatchFrameEvent(target, opcode, a))
            {
                return 0;
            }

            // Unknown target: log + drop. Matches previous behaviour
            // (the prior dispatcher emitted the same log line).
            // DIAG: explicit miss marker — if River is timing out on a
            // ping, the manager's target will surface here every ~1s.
            RiverWindowManagerClient.Log("DISPATCH-MISS target=0x" + target.ToString("x") + " opcode=" + opcode);
        }
        catch (Exception e)
        {
            // NEVER unwind into native dispatch.
            try
            {
                RiverWindowManagerClient.Log("dispatch exception: " + e.Message);
            }
            catch
            {
            }
        }

        return 0;
    }
}
