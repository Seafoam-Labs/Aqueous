using System;
using System.Runtime.InteropServices;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Wire-format union for one argument passed by libwayland's
/// dispatcher callback. Layout matches <c>wl_argument</c> from
/// <c>wayland-util.h</c>; field naming mirrors the upstream short
/// names (<c>i</c>, <c>u</c>, <c>fx</c>, <c>s</c>, <c>o</c>, <c>n</c>,
/// <c>a</c>, <c>h</c>) so call sites that index the original
/// <c>WlArgument*</c> pointer continue to read identically. Promoted
/// out of the nested-struct declaration inside
/// <see cref="RiverWindowManagerClient"/> during the Phase 2
/// readability refactor.
/// </summary>
[StructLayout(LayoutKind.Explicit)]
internal struct WlArgument
{
    [FieldOffset(0)] public int i;
    [FieldOffset(0)] public uint u;
    [FieldOffset(0)] public int fx;
    [FieldOffset(0)] public IntPtr s;
    [FieldOffset(0)] public IntPtr o;
    [FieldOffset(0)] public uint n;
    [FieldOffset(0)] public IntPtr a;
    [FieldOffset(0)] public int h;
}
