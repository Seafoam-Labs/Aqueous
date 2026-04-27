using System;

namespace Aqueous.Features.State;

/// <summary>
/// Strongly-typed wrapper around a Wayland-compositor window handle.
/// Phase 2 / Step 8.B introduces these wrappers so window/output/seat
/// handles cannot be accidentally swapped at call sites — the three
/// proxy types are layout-compatible with <see cref="IntPtr"/> but
/// carry distinct identities at the type level.
///
/// <para>Living in <c>Aqueous.Features.State</c> (rather than under
/// <c>River/</c>) keeps the WM-protocol-agnostic <see cref="IWindowStateHost"/>
/// surface free of any compositor-specific dependency.</para>
/// </summary>
/// <param name="Handle">The raw handle. Use <see cref="IsZero"/> to test for the null handle.</param>
public readonly record struct WindowProxy(IntPtr Handle)
{
    /// <summary>The null window proxy.</summary>
    public static WindowProxy Zero => default;

    /// <summary>True if this proxy is the null handle.</summary>
    public bool IsZero => Handle == IntPtr.Zero;

    public override string ToString() => $"WindowProxy(0x{Handle.ToInt64():x})";
}

/// <summary>
/// Strongly-typed wrapper around a Wayland-compositor output (display)
/// handle. See <see cref="WindowProxy"/> for the rationale.
/// </summary>
/// <param name="Handle">The raw handle.</param>
public readonly record struct OutputProxy(IntPtr Handle)
{
    /// <summary>The null output proxy.</summary>
    public static OutputProxy Zero => default;

    /// <summary>True if this proxy is the null handle.</summary>
    public bool IsZero => Handle == IntPtr.Zero;

    public override string ToString() => $"OutputProxy(0x{Handle.ToInt64():x})";
}

/// <summary>
/// Strongly-typed wrapper around a Wayland-compositor seat (input device
/// set) handle. See <see cref="WindowProxy"/> for the rationale.
/// </summary>
/// <param name="Handle">The raw handle.</param>
public readonly record struct SeatProxy(IntPtr Handle)
{
    /// <summary>The null seat proxy.</summary>
    public static SeatProxy Zero => default;

    /// <summary>True if this proxy is the null handle.</summary>
    public bool IsZero => Handle == IntPtr.Zero;

    public override string ToString() => $"SeatProxy(0x{Handle.ToInt64():x})";
}
