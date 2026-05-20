using System;

namespace Aqueous.Features.Compositor.River.Dispatch;

/// <summary>
/// Managed, allocation-free representation of a single Wayland event destined for an <see
/// cref="IEventHandler"/>. This type is the seam between the native <c>[UnmanagedCallersOnly]</c>
/// dispatcher inside <c>RiverWindowManagerClient</c> and the managed, per-interface handler model.
/// The native callback decodes the firing proxy's interface name, opcode, and the raw
/// <c>WlArgument*</c> payload, then constructs a <see cref="WlEvent"/> and hands it to <see
/// cref="IEventDispatcher"/>.
/// <para>
/// extended the struct from the original <c>(InterfaceName, Opcode,
/// ReadOnlyMemory&lt;byte&gt;)</c> shape to also carry the firing proxy <see cref="Target"/>, the
/// raw <c>WlArgument*</c> pointer (<see cref="ArgsPtr"/>) and <see cref="ArgCount"/>. Handlers
/// extracted decode their arguments through <see cref="WlArgumentDecoder"/> reading directly off
/// <see cref="ArgsPtr"/>; the managed <see cref="Args"/> memory remains available for handlers
/// that prefer to copy first (today none do).
/// </para>
/// Existing public constructors are for backward compatibility with tests written against the
/// original shape.
/// </summary>
public readonly struct WlEvent
{
    /// <summary>
    /// Wayland interface name of the firing proxy (e.g. <c>"wl_seat"</c>,
    /// <c>"zriver_window_manager_v3"</c>). Compared with <see cref="StringComparer.Ordinal"/> in the
    /// dispatch table; case-sensitive.
    /// </summary>
    public string InterfaceName { get; }

    /// <summary>
    /// Event opcode as defined by the Wayland protocol XML.
    /// </summary>
    public uint Opcode { get; }

    /// <summary>
    /// Firing proxy handle (the native <c>wl_proxy*</c> the event was addressed to). <see
    /// cref="IntPtr.Zero"/> when the event was synthesized in a test.
    /// </summary>
    public IntPtr Target { get; }

    /// <summary>
    /// Raw <c>WlArgument*</c> pointer into the libwayland-owned argument array for this event. <see
    /// cref="IntPtr.Zero"/> for events constructed without a native payload. Lifetime is the duration
    /// of the dispatcher callback only — handlers must not store this pointer.
    /// </summary>
    public IntPtr ArgsPtr { get; }

    /// <summary>
    /// Number of arguments in the array pointed to by <see cref="ArgsPtr"/>. Zero for events with no
    /// arguments or for events constructed without a native payload.
    /// </summary>
    public int ArgCount { get; }

    /// <summary>
    /// Optional managed-memory payload. Original seam; preserved so the 9 existing
    /// <c>EventDispatcherTests</c> remain green and so handlers that prefer a managed buffer over the
    /// raw pointer have a place to read from. May be empty.
    /// </summary>
    public ReadOnlyMemory<byte> Args { get; }

    /// <summary>
    /// Ctor — synthetic event, no payload.
    /// </summary>
    public WlEvent(string interfaceName, uint opcode)
        : this(interfaceName, opcode, ReadOnlyMemory<byte>.Empty)
    {
    }

    /// <summary>
    /// Ctor — synthetic event with managed payload.
    /// </summary>
    public WlEvent(string interfaceName, uint opcode, ReadOnlyMemory<byte> args)
    {
        InterfaceName = interfaceName ?? throw new ArgumentNullException(nameof(interfaceName));
        Opcode = opcode;
        Args = args;
        Target = IntPtr.Zero;
        ArgsPtr = IntPtr.Zero;
        ArgCount = 0;
    }

    /// <summary>
    /// Ctor — full native payload, used by the native callback once the if/else chain has been
    /// rewritten. Tests can also synthesize fully-populated events via this ctor.
    /// </summary>
    /// <param name="interfaceName">
    /// Wayland interface name; must be non-null and non-empty.
    /// </param>
    /// <param name="target">
    /// Firing proxy handle.
    /// </param>
    /// <param name="opcode">
    /// Event opcode.
    /// </param>
    /// <param name="argsPtr">
    /// Raw <c>WlArgument*</c> pointer (may be <see cref="IntPtr.Zero"/>).
    /// </param>
    /// <param name="argCount">
    /// Number of arguments referenced by <paramref name="argsPtr"/>; must be &gt;= 0.
    /// </param>
    public WlEvent(string interfaceName, IntPtr target, uint opcode, IntPtr argsPtr, int argCount)
    {
        InterfaceName = interfaceName ?? throw new ArgumentNullException(nameof(interfaceName));
        if (argCount < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(argCount), argCount, "argCount must be non-negative.");
        }
        Opcode = opcode;
        Target = target;
        ArgsPtr = argsPtr;
        ArgCount = argCount;
        Args = ReadOnlyMemory<byte>.Empty;
    }
}
