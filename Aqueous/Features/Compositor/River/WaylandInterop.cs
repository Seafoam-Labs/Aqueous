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
/// <see cref="ForeignToplevelClient"/> initialization (see
/// <see cref="WlInterfaces.EnsureBuilt"/>).</item>
/// <item>All dispatch happens on a dedicated worker thread owned by
/// <c>ForeignToplevelClient</c>, independent from GTK's own GDK-Wayland
/// connection.</item>
/// </list>
/// </para>
/// </summary>
internal static unsafe partial class WaylandInterop
{
    /// <summary>
    /// SONAME of the libwayland client library this interop layer binds to.
    /// <para>
    /// Pinned to the stable <c>.so.0</c> ABI line because libwayland has
    /// shipped that single soname version since its inception; loading the
    /// versionless <c>libwayland-client.so</c> would require the <c>-devel</c>
    /// package to be installed at runtime, which we cannot assume on end-user
    /// systems.
    /// </para>
    /// </summary>
    private const string Lib = "libwayland-client.so.0";

    // ---------------- wl_display ----------------

    /// <summary>
    /// Connects to a Wayland compositor and returns the resulting
    /// <c>wl_display</c> handle.
    /// </summary>
    /// <param name="name">
    /// Pointer to a NUL-terminated UTF-8 socket name. Pass
    /// <see cref="IntPtr.Zero"/> to use the default selection logic
    /// (<c>WAYLAND_DISPLAY</c> environment variable, falling back to
    /// <c>wayland-0</c>).
    /// </param>
    /// <returns>
    /// Native <c>wl_display*</c> on success, or <see cref="IntPtr.Zero"/> if
    /// no compositor could be reached.
    /// </returns>
    [LibraryImport(Lib)] public static partial IntPtr wl_display_connect(IntPtr name);

    /// <summary>
    /// Closes the connection and frees the <c>wl_display</c>.
    /// </summary>
    /// <param name="display">Handle previously returned by <see cref="wl_display_connect"/>.</param>
    /// <remarks>
    /// Must be called exactly once, on the same thread that owns the
    /// dispatch loop. After this call every proxy derived from
    /// <paramref name="display"/> is invalid.
    /// </remarks>
    [LibraryImport(Lib)] public static partial void wl_display_disconnect(IntPtr display);

    /// <summary>
    /// Reads and dispatches events from the compositor, blocking until at
    /// least one event has been processed.
    /// </summary>
    /// <param name="display">A live <c>wl_display</c> handle.</param>
    /// <returns>
    /// The number of events dispatched, or <c>-1</c> on error (in which case
    /// the connection is broken and <c>errno</c> describes the cause).
    /// </returns>
    [LibraryImport(Lib)] public static partial int wl_display_dispatch(IntPtr display);

    /// <summary>
    /// Performs a synchronous round-trip: flushes outgoing requests and
    /// blocks until the compositor has answered every one of them.
    /// </summary>
    /// <param name="display">A live <c>wl_display</c> handle.</param>
    /// <returns>The number of events dispatched, or <c>-1</c> on error.</returns>
    /// <remarks>
    /// Used during initial bind to make sure all <c>wl_registry.global</c>
    /// events have been delivered before we look up our protocol globals.
    /// </remarks>
    [LibraryImport(Lib)] public static partial int wl_display_roundtrip(IntPtr display);

    /// <summary>
    /// Sends every queued outgoing request to the compositor without
    /// blocking.
    /// </summary>
    /// <param name="display">A live <c>wl_display</c> handle.</param>
    /// <returns>
    /// The number of bytes sent, or <c>-1</c> if the kernel buffer is full
    /// (<c>errno</c> = <c>EAGAIN</c>); the recommended pattern is to poll the
    /// fd from <see cref="wl_display_get_fd"/> for <c>POLLOUT</c> and retry.
    /// </returns>
    [LibraryImport(Lib)] public static partial int wl_display_flush(IntPtr display);

    /// <summary>
    /// Returns the file descriptor backing the compositor connection,
    /// suitable for use with <c>poll(2)</c> / <c>epoll</c>.
    /// </summary>
    /// <param name="display">A live <c>wl_display</c> handle.</param>
    /// <returns>The underlying socket fd. Owned by libwayland — do not close it.</returns>
    [LibraryImport(Lib)] public static partial int wl_display_get_fd(IntPtr display);

    // ---------------- wl_proxy ----------------

    /// <summary>
    /// Generic request marshaller. Up to 6 arg slots cover every request we
    /// send (the biggest is <c>wl_registry.bind</c> at 4 args). Slots not
    /// used by the message MUST be <c>IntPtr.Zero</c>.
    /// </summary>
    /// <param name="proxy">Target proxy that owns the request being sent.</param>
    /// <param name="opcode">
    /// Zero-based index into the <c>methods</c> array of the proxy's
    /// <see cref="WlInterface"/>.
    /// </param>
    /// <param name="iface">
    /// Pointer to the <see cref="WlInterface"/> describing the new object
    /// when the request creates one (signature contains <c>n</c>); pass
    /// <see cref="IntPtr.Zero"/> otherwise.
    /// </param>
    /// <param name="version">
    /// Version to assign to the newly created proxy when <paramref name="iface"/>
    /// is non-null; ignored otherwise.
    /// </param>
    /// <param name="flags">
    /// Bit flags. Currently only <see cref="WL_MARSHAL_FLAG_DESTROY"/> is
    /// defined, which destroys <paramref name="proxy"/> after the request is
    /// queued.
    /// </param>
    /// <param name="a0">Slot 0 — first wire argument (or <see cref="IntPtr.Zero"/> if unused).</param>
    /// <param name="a1">Slot 1 — second wire argument (or <see cref="IntPtr.Zero"/> if unused).</param>
    /// <param name="a2">Slot 2 — third wire argument (or <see cref="IntPtr.Zero"/> if unused).</param>
    /// <param name="a3">Slot 3 — fourth wire argument (or <see cref="IntPtr.Zero"/> if unused).</param>
    /// <param name="a4">Slot 4 — fifth wire argument (or <see cref="IntPtr.Zero"/> if unused).</param>
    /// <param name="a5">Slot 5 — sixth wire argument (or <see cref="IntPtr.Zero"/> if unused).</param>
    /// <returns>
    /// The newly created proxy (when the request has a <c>new_id</c>
    /// argument), or <see cref="IntPtr.Zero"/> for plain requests.
    /// </returns>
    [LibraryImport(Lib)]
    public static partial IntPtr wl_proxy_marshal_flags(
        IntPtr proxy, uint opcode, IntPtr iface, uint version, uint flags,
        IntPtr a0, IntPtr a1, IntPtr a2, IntPtr a3, IntPtr a4, IntPtr a5);

    /// <summary>
    /// Releases a proxy that was previously returned by
    /// <see cref="wl_proxy_marshal_flags"/>.
    /// </summary>
    /// <param name="proxy">The proxy to free. Must not be <see cref="IntPtr.Zero"/>.</param>
    /// <remarks>
    /// Does not send any wire message. To both destroy the server-side
    /// object and free the proxy, call <see cref="wl_proxy_marshal_flags"/>
    /// with the <c>destroy</c> opcode and <see cref="WL_MARSHAL_FLAG_DESTROY"/>.
    /// </remarks>
    [LibraryImport(Lib)] public static partial void wl_proxy_destroy(IntPtr proxy);

    /// <summary>
    /// Registers a single dispatcher callback that receives every event
    /// addressed to <paramref name="proxy"/>.
    /// </summary>
    /// <param name="proxy">The proxy to attach the dispatcher to.</param>
    /// <param name="dispatcher">
    /// Function pointer with signature
    /// <c>delegate* unmanaged&lt;IntPtr, IntPtr, uint, IntPtr, IntPtr, int&gt;</c>
    /// — that is,
    /// <c>(implementation, proxy, opcode, wl_message*, wl_argument*) -&gt; int</c>.
    /// See <c>Aqueous.Features.Compositor.River.Dispatch.ProxyDispatcher</c>
    /// and the per-handler types
    /// (<c>ManagerEventHandler</c>, <c>WindowEventHandler</c>,
    /// <c>LayerShellEventHandler</c>) for the in-tree implementation.
    /// </param>
    /// <param name="implementation">
    /// Opaque value forwarded as the <c>implementation</c> argument to the
    /// dispatcher. We pack a managed <see cref="System.Runtime.InteropServices.GCHandle"/>
    /// (via <c>GCHandle.ToIntPtr</c>) so the callback can recover the C#
    /// receiver instance.
    /// </param>
    /// <param name="data">Extra user data forwarded to libwayland; we always pass <see cref="IntPtr.Zero"/>.</param>
    /// <returns><c>0</c> on success, non-zero on error.</returns>
    /// <remarks>
    /// The dispatcher is invoked on libwayland's dispatch thread (i.e. the
    /// thread currently running <see cref="wl_display_dispatch"/>). All
    /// access to managed state from inside it must therefore be thread-safe.
    /// </remarks>
    [LibraryImport(Lib)]
    public static partial int wl_proxy_add_dispatcher(
        IntPtr proxy, IntPtr dispatcher, IntPtr implementation, IntPtr data);

    /// <summary>
    /// Flag bit consumed by <see cref="wl_proxy_marshal_flags"/> that causes
    /// the target proxy to be destroyed immediately after the request has
    /// been queued. Used for destructor requests such as
    /// <c>wl_proxy.destroy</c>.
    /// </summary>
    public const uint WL_MARSHAL_FLAG_DESTROY = 1u;

    // ---------------- wl_interface / wl_message layout ----------------

    /// <summary>ABI-compatible mirror of libwayland's <c>struct wl_message</c>.</summary>
    [StructLayout(LayoutKind.Sequential)]
    public struct WlMessage
    {
        /// <summary>
        /// Pointer to the NUL-terminated UTF-8 wire name of the message
        /// (e.g. <c>"bind"</c>, <c>"global"</c>).
        /// </summary>
        public IntPtr name;       // const char*

        /// <summary>
        /// Pointer to the NUL-terminated libwayland signature string
        /// describing the wire arguments. Each character is a type code
        /// (<c>i</c>, <c>u</c>, <c>f</c>, <c>s</c>, <c>o</c>, <c>n</c>,
        /// <c>a</c>, <c>h</c>), optionally prefixed by a <c>?</c> for
        /// nullable args and/or a decimal "since" version number.
        /// </summary>
        public IntPtr signature;  // const char*

        /// <summary>
        /// Pointer to a contiguous <c>wl_interface**</c> array, one entry
        /// per signature argument. Entries corresponding to non-typed args
        /// (<c>i</c>, <c>u</c>, <c>s</c>, …) are <c>NULL</c>; entries for
        /// <c>o</c> / <c>n</c> point at the related <see cref="WlInterface"/>.
        /// </summary>
        public IntPtr types;      // const wl_interface**
    }

    /// <summary>ABI-compatible mirror of libwayland's <c>struct wl_interface</c>.</summary>
    /// <remarks>
    /// Instances of this struct live in unmanaged memory and are produced
    /// by <see cref="WlInterfaces"/> (e.g. <c>WlInterfaces.AllocInterface</c>).
    /// They are passed to <see cref="wl_proxy_marshal_flags"/> via the
    /// <c>iface</c> parameter to type new proxies.
    /// </remarks>
    [StructLayout(LayoutKind.Sequential)]
    public struct WlInterface
    {
        /// <summary>Pointer to the NUL-terminated UTF-8 interface name (e.g. <c>"wl_registry"</c>).</summary>
        public IntPtr name;          // const char*

        /// <summary>Highest protocol version supported by this interface description.</summary>
        public int version;

        /// <summary>Number of entries in <see cref="methods"/>; matches the request opcode space.</summary>
        public int method_count;  // requests

        /// <summary>
        /// Pointer to a contiguous array of <see cref="WlMessage"/> describing
        /// the interface's requests, indexed by opcode. Length is
        /// <see cref="method_count"/>.
        /// </summary>
        public IntPtr methods;       // WlMessage*

        /// <summary>Number of entries in <see cref="events"/>; matches the event opcode space.</summary>
        public int event_count;

        /// <summary>
        /// Pointer to a contiguous array of <see cref="WlMessage"/> describing
        /// the interface's events, indexed by opcode. Length is
        /// <see cref="event_count"/>.
        /// </summary>
        public IntPtr events;        // WlMessage*
    }
}
