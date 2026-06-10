using System;
using System.Collections.Concurrent;
using Aqueous.Features.Compositor.River.Dispatch;

namespace Aqueous.Features.Compositor.River.Connection;

/// <summary>
/// Singleton holder for the raw Wayland proxy pointers established at global-bind time
/// (river_window_manager_v1, zwlr_layer_shell_v1, zwlr_screencopy_manager_v1, wl_shm,
/// river_xkb_v1) plus the proxy → interface-name tracker. Introduced to peel bind-site ownership
/// away from <c>RiverWindowManagerClient</c>.
/// <para>
/// During the incremental lift this singleton is populated alongside the existing private fields
/// on <c>RiverWindowManagerClient</c>; once every consumer takes <c>WaylandBindSiteState</c> via
/// ctor injection, the duplicated fields on the god class are removed.
/// </para>
/// </summary>
internal sealed class WaylandBindSiteState
{
    public IntPtr Manager { get; set; }
    public IntPtr LayerShell { get; set; }
    public IntPtr ScreencopyManager { get; set; }
    public IntPtr WlShm { get; set; }
    public IntPtr XkbBindings { get; set; }

    /// <summary>
    /// The bound <c>ext_workspace_manager_v1</c> global. <see cref="IntPtr.Zero"/> until the
    /// compositor advertises and we bind it. Used to issue <c>commit</c> after batching
    /// <c>activate</c>/<c>create_workspace</c> requests on workspace/group handles.
    /// </summary>
    public IntPtr WorkspaceManager { get; set; }

    /// <summary>
    /// The bound <c>river_libinput_config_v1</c> global (set at registry global discovery time).
    /// Used by <c>LibinputConfigApplier</c> as the parent for every per-device proxy emitted by the
    /// compositor's libinput layer.
    /// </summary>
    public IntPtr LibinputConfig { get; set; }
    /// <summary>
    /// Protocol version advertised by the bound <c>river_xkb_bindings_v1</c> global. Captured at bind
    /// time so child <c>river_xkb_binding_v1</c> proxies created by <see
    /// cref="Aqueous.Features.Bindings.KeyBindingRegistrar"/> can be bound at the parent's advertised
    /// version rather than a hardcoded literal (a future river bump would otherwise assert inside
    /// libwayland on first event dispatch).
    /// </summary>
    public uint XkbBindingsVersion { get; set; }

    /// <summary>
    /// Protocol version advertised by the bound <c>zwlr_screencopy_manager_v1</c> global. Captured at
    /// bind time so on-demand capture proxies can be requested at the parent's advertised version.
    /// </summary>
    public uint ScreencopyVersion { get; set; }

    /// <summary>
    /// Cache of every advertised <c>wl_output</c> global (lazy-bind: we only record the global here
    /// and bind on-demand inside the capture path, then destroy the proxy immediately).
    /// </summary>
    public ConcurrentDictionary<uint, RegistryGlobal> WlOutputGlobals { get; } = new();

    /// <summary>
    /// The bound <c>river_super_key_binding_v1</c> proxy (set at registry global discovery time).
    /// </summary>
    public IntPtr SuperKeyBinding { get; set; }

    /// <summary>
    /// <c>river_seat_v1</c> proxy → its <c>river_layer_shell_seat_v1</c> sub-object (created via
    /// <c>river_layer_shell_v1.get_seat</c>). Lets teardown destroy the sub-object when the parent
    /// seat is removed.
    /// </summary>
    public ConcurrentDictionary<IntPtr, IntPtr> LayerShellSeatBySeat { get; } = new();

    /// <summary>
    /// Reverse of <see cref="LayerShellSeatBySeat"/>: <c>river_layer_shell_seat_v1</c> proxy → its
    /// parent <c>river_seat_v1</c>. Lets focus events resolve the controlled seat from the incoming
    /// sub-object proxy.
    /// </summary>
    public ConcurrentDictionary<IntPtr, IntPtr> SeatByLayerShellSeat { get; } = new();

    /// <summary>
    /// <c>river_output_v1</c> proxy → its <c>river_layer_shell_output_v1</c> sub-object (created via
    /// <c>river_layer_shell_v1.get_output</c>).
    /// </summary>
    public ConcurrentDictionary<IntPtr, IntPtr> LayerShellOutputByOutput { get; } = new();

    /// <summary>
    /// Reverse of <see cref="LayerShellOutputByOutput"/>: <c>river_layer_shell_output_v1</c> proxy →
    /// its parent <c>river_output_v1</c>. Lets <c>non_exclusive_area</c> resolve the output for
    /// layout.
    /// </summary>
    public ConcurrentDictionary<IntPtr, IntPtr> OutputByLayerShellOutput { get; } = new();

    /// <summary>
    /// Proxy → interface-name map populated at every <c>wl_registry::bind</c> callsite. Stage-0 of the
    /// dispatch decomposition introduced this as a write-only seam; it now lives on the singleton so
    /// consumers no longer need a reference to the god class to record/lookup names.
    /// </summary>
    public ProxyInterfaceMap ProxyInterface { get; } = new();

    public void TrackProxyInterface(IntPtr proxy, string interfaceName)
        => ProxyInterface.Track(proxy, interfaceName);

    public string? TryGetProxyInterface(IntPtr proxy)
        => ProxyInterface.TryGet(proxy);

    public bool UntrackProxyInterface(IntPtr proxy)
        => ProxyInterface.Untrack(proxy);

    public int TrackedProxyCount => ProxyInterface.Count;
}
