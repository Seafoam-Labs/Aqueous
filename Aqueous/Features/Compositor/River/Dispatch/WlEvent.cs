using System;

namespace Aqueous.Features.Compositor.River.Dispatch;

/// <summary>
/// Managed, allocation-free representation of a single Wayland event
/// destined for an <see cref="IEventHandler"/>.
///
/// This type is the seam between the native <c>[UnmanagedCallersOnly]</c>
/// dispatcher inside <c>RiverWindowManagerClient</c> and the managed,
/// per-interface handler model introduced in Step 4 of the Phase 2
/// refactor. The native callback decodes the firing proxy's interface
/// name, opcode, and the raw <c>WlArgument*</c> payload, then constructs
/// a <see cref="WlEvent"/> and hands it to <see cref="IEventDispatcher"/>.
///
/// The payload is carried as <see cref="ReadOnlyMemory{Byte}"/> rather
/// than <see cref="ReadOnlySpan{Byte}"/> so the event can be stored in
/// fields by handlers that defer work; in the hot path handlers should
/// call <see cref="ReadOnlyMemory{T}.Span"/> on first access.
/// </summary>
public readonly struct WlEvent
{
    /// <summary>
    /// Wayland interface name of the firing proxy
    /// (e.g. <c>"wl_seat"</c>, <c>"zriver_window_manager_v3"</c>).
    /// Compared with <see cref="StringComparer.Ordinal"/> in the
    /// dispatch table; case-sensitive.
    /// </summary>
    public string InterfaceName { get; }

    /// <summary>Event opcode as defined by the Wayland protocol XML.</summary>
    public uint Opcode { get; }

    /// <summary>
    /// Opaque argument payload. Layout is protocol-defined and decoded
    /// by the handler. May be empty for events with no arguments.
    /// </summary>
    public ReadOnlyMemory<byte> Args { get; }

    public WlEvent(string interfaceName, uint opcode, ReadOnlyMemory<byte> args)
    {
        InterfaceName = interfaceName ?? throw new ArgumentNullException(nameof(interfaceName));
        Opcode = opcode;
        Args = args;
    }

    public WlEvent(string interfaceName, uint opcode)
        : this(interfaceName, opcode, ReadOnlyMemory<byte>.Empty)
    {
    }
}
