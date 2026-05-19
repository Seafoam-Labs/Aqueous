using System;
using System.Runtime.InteropServices;

namespace Aqueous.Features.Compositor.River;

// PR 8.8 — final Stage-8 native callback rewrite. Replaces the
// old proxy-pointer-keyed if/else chain in ProxyDispatcher.cs with
// a single interface-name lookup against the Stage-0 _proxyInterface
// map, then dispatches via the managed IEventDispatcher. Screencopy
// frame proxies are owned by WlrScreencopyClient and never tracked
// in _proxyInterface, so they keep their dedicated fallback through
// IScreencopyService.TryDispatchFrameEvent.
//
// Behaviour is byte-for-byte equivalent to the prior dispatcher:
// every IEventHandler currently delegates back to the original
// `OnXxxEvent` partial body via its bridge's `HandleByPartial`
// (PRs 8.3-8.7 staged-rollout pattern). The opcode allowlist on
// each handler stays empty until each opcode is smoke-tested
// against the real River compositor.
//
// File previously named ProxyDispatcher.cs; renamed to
// NativeDispatchBridge.cs to reflect the new responsibility
// (bridge from native libwayland callback to managed dispatcher).
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
                Log("DISPATCH iface=" + iface + " target=0x" + target.ToString("x") + " opcode=" + opcode);
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
                self._eventDispatcher.Dispatch(
                    new Aqueous.Features.Compositor.River.Dispatch.WlEvent(
                        iface, target, opcode, (IntPtr)a, argCount));
                return 0;
            }

            // Fallback: screencopy frame proxies are owned by
            // WlrScreencopyClient and not tracked in _proxyInterface
            // (they live in the client's own per-frame state). The
            // ScreencopyFrameHandler IEventHandler is registered for
            // when frames eventually graduate into _proxyInterface,
            // but until then we keep the direct service call.
            if (self._screencopyService.TryDispatchFrameEvent(target, opcode, a))
            {
                return 0;
            }

            // Unknown target: log + drop. Matches previous behaviour
            // (the prior dispatcher emitted the same log line).
            // DIAG: explicit miss marker — if River is timing out on a
            // ping, the manager's target will surface here every ~1s.
            Log("DISPATCH-MISS target=0x" + target.ToString("x") + " opcode=" + opcode);
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
