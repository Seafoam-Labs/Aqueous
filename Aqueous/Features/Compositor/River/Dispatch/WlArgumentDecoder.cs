using System;
using System.Runtime.InteropServices;

namespace Aqueous.Features.Compositor.River.Dispatch;

/// <summary>
/// Pointer-arithmetic-only decoder for libwayland's <c>wl_argument</c>
/// union, packaged as a static helper so per-interface handlers
/// extracted in Stage 8 (PRs 8.1–8.7) can read their event arguments
/// without each one redefining the layout.
///
/// <para>
/// ABI: libwayland's <c>wl_argument</c> is a union of
/// <c>int32_t</c> / <c>uint32_t</c> / <c>wl_fixed_t</c> /
/// <c>const char*</c> / <c>wl_object*</c> / <c>uint32_t</c> (new_id) /
/// <c>wl_array*</c> / <c>int32_t</c> (fd). The union is sized to
/// <c>sizeof(void*)</c> on every platform libwayland supports, and the
/// dispatcher receives them as a contiguous array indexed by signature
/// position. We model each slot as a pointer-sized cell and reinterpret
/// it as needed.
/// </para>
///
/// <para>
/// All helpers are <c>unsafe</c> and take a <c>WlArgument*</c>-equivalent
/// <see cref="IntPtr"/> plus an index. None of them allocate; the string
/// helper marshals via <see cref="Marshal.PtrToStringUTF8(IntPtr)"/>
/// which copies into a managed <see cref="string"/> — handlers that
/// need allocation-free string access should call
/// <see cref="GetStringPtr"/> and pin/copy themselves.
/// </para>
///
/// <para>
/// Bounds: callers are responsible for bounds-checking against
/// <see cref="WlEvent.ArgCount"/>. The helpers do not, to keep the hot
/// path free of branches.
/// </para>
/// </summary>
internal static unsafe class WlArgumentDecoder
{
    /// <summary>Size of one <c>wl_argument</c> slot in bytes — always <c>sizeof(void*)</c>.</summary>
    public static int SlotSize => sizeof(nint);

    private static nint* Slots(IntPtr argsPtr) => (nint*)argsPtr;

    /// <summary>
    /// Read the <paramref name="index"/>-th slot as a signed 32-bit
    /// integer (signature codes <c>i</c> and <c>h</c>/fd).
    /// </summary>
    public static int GetInt(IntPtr argsPtr, int index)
    {
        // wl_argument.i lives in the low 32 bits of the slot regardless
        // of pointer size; reading via int* gives the same value as
        // libwayland's union access on every platform we care about.
        return *(int*)(Slots(argsPtr) + index);
    }

    /// <summary>
    /// Read the <paramref name="index"/>-th slot as an unsigned 32-bit
    /// integer (signature codes <c>u</c> and <c>n</c>/new_id).
    /// </summary>
    public static uint GetUInt(IntPtr argsPtr, int index)
    {
        return *(uint*)(Slots(argsPtr) + index);
    }

    /// <summary>
    /// Read the <paramref name="index"/>-th slot as a 24.8 fixed-point
    /// value (signature code <c>f</c>), returned as the raw 32-bit
    /// representation. Handlers convert to <see cref="double"/> via
    /// <see cref="FixedToDouble"/> if they need it.
    /// </summary>
    public static int GetFixed(IntPtr argsPtr, int index) => GetInt(argsPtr, index);

    /// <summary>
    /// Read the <paramref name="index"/>-th slot as a managed UTF-8
    /// string (signature code <c>s</c>). Returns <c>null</c> when the
    /// underlying pointer is NULL (libwayland encodes the
    /// <c>?s</c> nullable form this way).
    /// </summary>
    public static string? GetString(IntPtr argsPtr, int index)
    {
        var ptr = GetStringPtr(argsPtr, index);
        return ptr == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(ptr);
    }

    /// <summary>
    /// Read the <paramref name="index"/>-th slot as a raw
    /// <c>const char*</c> pointer (signature code <c>s</c>) without
    /// marshalling. Useful for hot paths where the handler will copy or
    /// hash the bytes directly.
    /// </summary>
    public static IntPtr GetStringPtr(IntPtr argsPtr, int index)
    {
        return *(IntPtr*)(Slots(argsPtr) + index);
    }

    /// <summary>
    /// Read the <paramref name="index"/>-th slot as an opaque
    /// <c>wl_object*</c> / <c>wl_proxy*</c> handle (signature code
    /// <c>o</c>). Returns <see cref="IntPtr.Zero"/> for the nullable
    /// <c>?o</c> form.
    /// </summary>
    public static IntPtr GetObject(IntPtr argsPtr, int index)
    {
        return *(IntPtr*)(Slots(argsPtr) + index);
    }

    /// <summary>
    /// Read the <paramref name="index"/>-th slot as a pointer to a
    /// <c>wl_array</c> struct (signature code <c>a</c>). The
    /// <c>wl_array</c> contains <c>(size, alloc, data)</c>; callers that
    /// need the contents should use a dedicated helper layered on top.
    /// </summary>
    public static IntPtr GetArrayPtr(IntPtr argsPtr, int index)
    {
        return *(IntPtr*)(Slots(argsPtr) + index);
    }

    /// <summary>
    /// Read the <paramref name="index"/>-th slot as a file descriptor
    /// (signature code <c>h</c>). Same wire form as <see cref="GetInt"/>;
    /// this helper exists for call-site readability only.
    /// </summary>
    public static int GetFd(IntPtr argsPtr, int index) => GetInt(argsPtr, index);

    /// <summary>
    /// Convert a libwayland 24.8 fixed-point value (as returned by
    /// <see cref="GetFixed"/>) to <see cref="double"/>.
    /// </summary>
    public static double FixedToDouble(int wlFixed) => wlFixed / 256.0;
}
