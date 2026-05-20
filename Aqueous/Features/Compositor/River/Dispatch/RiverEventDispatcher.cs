using System;
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

    internal void HandleSuperKeyBindingEvent(uint opcode, WlArgument* args)
        => _client.HandleSuperKeyBindingEvent(opcode, args);

    internal void HandleDragPointerBindingEvent(IntPtr target, uint opcode, WlArgument* args)
        => _client.HandleDragPointerBindingEvent(target, opcode, args);

    internal void HandleWindowEvent(IntPtr proxy, uint opcode, WlArgument* args)
        => _client.HandleWindowEvent(proxy, opcode, args);

    internal void HandleManagerEvent(uint opcode, WlArgument* args)
        => _client.HandleManagerEvent(opcode, args);
}
