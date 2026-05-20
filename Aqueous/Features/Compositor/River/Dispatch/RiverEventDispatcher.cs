using System;
using Aqueous.Diagnostics;
namespace Aqueous.Features.Compositor.River.Dispatch;

/// <summary>
/// Stage 9 PR 9.12 §2.10 — top-level event dispatcher seam. Owns the
/// five <c>Handle*Event</c> entry points previously surfaced on the
/// god-class <see cref="RiverWindowManagerClient"/>. Each method
/// delegates to the existing entry point on the client so behaviour is
/// byte-for-byte equivalent — the lift is structural only.
///
/// <para>
/// In §2.13 (final demolition) the GCHandle pin will move from
/// <c>RiverWindowManagerClient._selfHandle</c> to a
/// <see cref="NativeCallbackContext"/> that points at an instance of
/// this dispatcher; <see cref="NativeCallbackEntry.Dispatch"/> will
/// then read the context off the GCHandle and route directly here,
/// removing the god class from the native callback path entirely.
/// </para>
/// </summary>
internal sealed unsafe class RiverEventDispatcher
{
    private readonly RiverWindowManagerClient _client;

    internal RiverEventDispatcher(RiverWindowManagerClient client)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
    }

    internal void HandleKeyBindingEvent(IntPtr target, uint opcode, WlArgument* args)
        => _client.HandleKeyBindingEvent(target, opcode, args);





    /// <summary>
    /// PR 9.12 §2.13 — owns the body previously inlined in
    /// <see cref="NativeCallbackEntry.Dispatch"/>. The native entry now
    /// rehydrates a <see cref="NativeCallbackContext"/> from the GCHandle
    /// and calls into this dispatcher, removing the direct
    /// <c>gch.Target as RiverWindowManagerClient</c> cast from the
    /// callback path. The body still reads god-class accessors
    /// (<c>TryGetProxyInterface</c>, <c>EventDispatcher</c>,
    /// <c>ScreencopyService</c>) until those collaborators are lifted in
    /// the final §2.13 demolition.
    /// </summary>
    internal int DispatchNative(IntPtr target, uint opcode, IntPtr args)
    {
        var a = (WlArgument*)args;

        var iface = _client.TryGetProxyInterface(target);
        if (iface is not null)
        {
            RiverLog.Write("DISPATCH iface=" + iface + " target=0x" + target.ToString("x") + " opcode=" + opcode);
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
            _client.EventDispatcher.Dispatch(
                new WlEvent(iface, target, opcode, (IntPtr)a, argCount));
            return 0;
        }

        if (_client.ScreencopyService.TryDispatchFrameEvent(target, opcode, a))
        {
            return 0;
        }

        RiverLog.Write("DISPATCH-MISS target=0x" + target.ToString("x") + " opcode=" + opcode);
        return 0;
    }
}
