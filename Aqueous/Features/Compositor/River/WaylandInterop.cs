using System;
using System.Runtime.InteropServices;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Minimal hand-rolled P/Invoke surface for <c>libwayland-client</c>,
/// used exclusively by <see cref="ForeignToplevelClient"/> to speak the
/// <c>zwlr_foreign_toplevel_management_v1</c> protocol.
///
/// <para>
/// Design notes:
/// <list type="bullet">
/// <item>Everything drives through two entry points: <see cref="wl_proxy_marshal_flags"/>
/// (sends a request) and <see cref="wl_proxy_add_dispatcher"/> (registers an
/// event callback). This avoids the per-message stubs that
/// <c>wayland-scanner</c> would normally produce.</item>
/// <item><see cref="WlInterface"/> / <see cref="WlMessage"/> mirror the libwayland
/// ABI exactly; instances are built once in unmanaged memory during
/// <see cref="ForeignToplevelClient"/> initialization.</item>
/// <item>All dispatch happens on a dedicated worker thread owned by
/// <c>ForeignToplevelClient</c>, independent from GTK's own GDK-Wayland
/// connection.</item>
/// </list>
/// </para>
/// </summary>
internal static unsafe partial class WaylandInterop
{
    private const string Lib = "libwayland-client.so.0";

    // ---------------- wl_display ----------------

    [LibraryImport(Lib)] public static partial IntPtr wl_display_connect(IntPtr name);
    [LibraryImport(Lib)] public static partial void wl_display_disconnect(IntPtr display);
    [LibraryImport(Lib)] public static partial int wl_display_dispatch(IntPtr display);
    [LibraryImport(Lib)] public static partial int wl_display_roundtrip(IntPtr display);
    [LibraryImport(Lib)] public static partial int wl_display_flush(IntPtr display);
    [LibraryImport(Lib)] public static partial int wl_display_get_fd(IntPtr display);

    // ---------------- wl_proxy ----------------

    /// <summary>
    /// Generic request marshaller. Up to 6 arg slots cover every request we
    /// send (the biggest is <c>wl_registry.bind</c> at 4 args). Slots not
    /// used by the message MUST be <c>IntPtr.Zero</c>.
    /// </summary>
    [LibraryImport(Lib)]
    public static partial IntPtr wl_proxy_marshal_flags(
        IntPtr proxy, uint opcode, IntPtr iface, uint version, uint flags,
        IntPtr a0, IntPtr a1, IntPtr a2, IntPtr a3, IntPtr a4, IntPtr a5);

    [LibraryImport(Lib)] public static partial void wl_proxy_destroy(IntPtr proxy);

    [LibraryImport(Lib)]
    public static partial int wl_proxy_add_dispatcher(
        IntPtr proxy, IntPtr dispatcher, IntPtr implementation, IntPtr data);

    public const uint WL_MARSHAL_FLAG_DESTROY = 1u;

    // ---------------- wl_interface / wl_message layout ----------------

    /// <summary>ABI-compatible mirror of libwayland's <c>struct wl_message</c>.</summary>
    [StructLayout(LayoutKind.Sequential)]
    public struct WlMessage
    {
        public IntPtr name;       // const char*
        public IntPtr signature;  // const char*
        public IntPtr types;      // const wl_interface**
    }

    /// <summary>ABI-compatible mirror of libwayland's <c>struct wl_interface</c>.</summary>
    [StructLayout(LayoutKind.Sequential)]
    public struct WlInterface
    {
        public IntPtr name;          // const char*
        public int version;
        public int method_count;  // requests
        public IntPtr methods;       // WlMessage*
        public int event_count;
        public IntPtr events;        // WlMessage*
    }
}
