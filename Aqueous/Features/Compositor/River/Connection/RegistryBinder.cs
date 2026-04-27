using System;

namespace Aqueous.Features.Compositor.River.Connection;

/// <summary>
/// Owns the <c>wl_registry</c> proxy for a connected <c>wl_display</c>
/// and turns the raw <c>global</c>/<c>global_remove</c> opcodes into
/// strongly-named <see cref="Discovered"/> / <see cref="Removed"/>
/// events so callers don't have to know wire-format details.
/// </summary>
/// <remarks>
/// This class is the single place that calls
/// <c>wl_display::get_registry</c> and the single place that issues
/// <c>wl_registry::bind</c>. Higher layers receive a
/// <see cref="RegistryGlobal"/> describing each advertised interface
/// and decide whether to call <see cref="Bind"/>; the resulting
/// <see cref="IntPtr"/> proxy is owned by the caller (typically
/// <c>RiverWindowManagerClient</c>), which is responsible for
/// installing a dispatcher on it.
/// </remarks>
internal sealed unsafe class RegistryBinder
{
    /// <summary>
    /// The native <c>wl_registry*</c> proxy. <see cref="IntPtr.Zero"/>
    /// until <see cref="Create"/> succeeds.
    /// </summary>
    public IntPtr Handle { get; private set; }

    /// <summary>
    /// Raised once per <c>wl_registry::global</c> event. Listeners may
    /// call <see cref="Bind"/> on the supplied
    /// <see cref="RegistryGlobal"/> to obtain a typed proxy.
    /// </summary>
    public event Action<RegistryGlobal>? Discovered;

    /// <summary>
    /// Raised once per <c>wl_registry::global_remove</c> event. The
    /// payload is the registry name advertised in the original
    /// <c>global</c>.
    /// </summary>
    public event Action<uint>? Removed;

    /// <summary>
    /// Calls <c>wl_display::get_registry</c> and installs
    /// <paramref name="dispatcher"/> on the resulting proxy so that
    /// registry events are routed to <see cref="HandleEvent"/>.
    /// </summary>
    /// <returns><c>true</c> when the registry proxy was created.</returns>
    public bool Create(IntPtr display, IntPtr dispatcher, IntPtr dispatcherData)
    {
        // wl_display::get_registry is opcode 1.
        Handle = WaylandInterop.wl_proxy_marshal_flags(
            display, 1, (IntPtr)WlInterfaces.WlRegistry, 1, 0,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        if (Handle == IntPtr.Zero)
        {
            return false;
        }

        WaylandInterop.wl_proxy_add_dispatcher(Handle, dispatcher, dispatcherData, IntPtr.Zero);
        return true;
    }

    /// <summary>
    /// Called by the owning dispatcher for every event whose
    /// <c>target</c> equals <see cref="Handle"/>. Fans the wire opcode
    /// out to <see cref="Discovered"/> / <see cref="Removed"/>.
    /// </summary>
    public void HandleEvent(uint opcode, WlArgument* args)
    {
        if (opcode == RiverProtocolOpcodes.Registry.Global)
        {
            uint name = args[0].u;
            string? iface = MarshalUtf8(args[1].s);
            uint version = args[2].u;
            if (iface == null)
            {
                return;
            }

            Discovered?.Invoke(new RegistryGlobal(name, iface, version));
        }
        else if (opcode == RiverProtocolOpcodes.Registry.GlobalRemove)
        {
            Removed?.Invoke(args[0].u);
        }
    }

    /// <summary>
    /// Issues <c>wl_registry::bind</c> for the supplied global,
    /// returning the freshly-allocated proxy (or
    /// <see cref="IntPtr.Zero"/> on failure). The caller must install
    /// a dispatcher on the returned proxy and own its lifetime.
    /// </summary>
    public IntPtr Bind(uint name, WaylandInterop.WlInterface* iface, uint version)
    {
        // wl_registry::bind(name: uint, new_id: untyped)
        // libwayland takes (name, iface_name, iface_version, new_id-placeholder)
        // on the wire; wl_proxy_marshal_flags fills the new_id implicitly.
        return WaylandInterop.wl_proxy_marshal_flags(
            Handle,
            0, // opcode
            (IntPtr)iface,
            version,
            0,
            (IntPtr)name,
            (IntPtr)iface->name,
            (IntPtr)version,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
    }

    private static string? MarshalUtf8(IntPtr p) =>
        p == IntPtr.Zero ? null : System.Runtime.InteropServices.Marshal.PtrToStringUTF8(p);
}

/// <summary>
/// Describes a single <c>wl_registry::global</c> advertisement. The
/// <see cref="Interface"/> is the upstream interface name (e.g.
/// <c>"river_window_manager_v1"</c>); <see cref="Version"/> is the
/// maximum version the compositor supports.
/// </summary>
internal readonly record struct RegistryGlobal(uint Name, string Interface, uint Version);
