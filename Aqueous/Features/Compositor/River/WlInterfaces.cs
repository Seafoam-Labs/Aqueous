using System;
using System.Runtime.InteropServices;
using System.Text;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Builds the unmanaged <c>wl_interface</c> + <c>wl_message</c> tables used by <see
/// cref="ForeignToplevelClient"/>.
/// <para>
/// libwayland-client is strict: every proxy must be tagged with a real <c>wl_interface*</c> whose
/// <c>methods</c> / <c>events</c> arrays exactly describe the wire protocol (message name,
/// signature string, and the nested interface pointers for <c>object</c> / <c>new_id</c> typed
/// args). We build only the four interfaces we actually touch:
/// </para>
/// <list type="bullet">
/// <item>
/// <c>wl_registry</c> — just enough to issue <c>bind</c> and read <c>global</c> /
/// <c>global_remove</c>.
/// </item>
/// <item>
/// <c>wl_seat</c> — only the interface identity; we never issue requests on it, we just hand its
/// proxy pointer to <c>zwlr_foreign_toplevel_handle_v1.activate</c>.
/// </item>
/// <item>
/// <c>zwlr_foreign_toplevel_manager_v1</c> v3.
/// </item>
/// <item>
/// <c>zwlr_foreign_toplevel_handle_v1</c> v3.
/// </item>
/// </list>
/// <para>
/// Every string / struct is allocated with <see cref="Marshal.AllocHGlobal(int)"/> and
/// intentionally never freed — these tables live for the process lifetime (matching what
/// wayland-scanner-generated C code does: they're static globals).
/// </para>
/// </summary>
internal static unsafe class WlInterfaces
{
    /// <summary>
    /// <c>wl_registry</c> V1 — used for <c>bind</c> and to read <c>global</c> / <c>global_remove</c>
    /// events.
    /// </summary>
    /// <remarks>
    /// Passed as the <c>iface</c> argument to <see cref="WaylandInterop.wl_proxy_marshal_flags"/>.
    /// </remarks>
    public static WaylandInterop.WlInterface* WlRegistry;

    /// <summary>
    /// <c>wl_seat</c> V7 — interface identity only; we never issue requests on it, only forward its
    /// proxy to <c>activate</c>.
    /// </summary>
    public static WaylandInterop.WlInterface* WlSeat;

    /// <summary>
    /// <c>wl_surface</c> V1 placeholder.
    /// </summary>
    /// <remarks>
    /// We never create or talk to <c>wl_surface</c>; this entry exists only so signatures referencing
    /// <c>wl_surface</c> (e.g. <c>set_rectangle</c>) have a non-null type pointer.
    /// </remarks>
    public static WaylandInterop.WlInterface* WlSurface;      // used as null placeholder for rectangle()

    /// <summary>
    /// <c>wl_output</c> V1 placeholder.
    /// </summary>
    /// <remarks>
    /// Used only to type <c>output_enter</c> / <c>output_leave</c> / <c>set_fullscreen</c> arguments;
    /// we never receive events on a <c>wl_output</c> proxy.
    /// </remarks>
    public static WaylandInterop.WlInterface* WlOutput;       // used as null placeholder for output_enter/leave

    /// <summary>
    /// <c>zwlr_foreign_toplevel_manager_v1</c> V3.
    /// </summary>
    public static WaylandInterop.WlInterface* ZwlrManager;

    /// <summary>
    /// <c>zwlr_foreign_toplevel_handle_v1</c> V3.
    /// </summary>
    public static WaylandInterop.WlInterface* ZwlrHandle;

    // River_window_management_v1 v4 graph (B1a skeleton).

    /// <summary>
    /// <c>river_window_manager_v1</c> V4 — top-level entry point of the River window management
    /// protocol.
    /// </summary>
    public static WaylandInterop.WlInterface* RiverWindowManager;

    /// <summary>
    /// <c>river_window_v1</c> V4 — per-window proxy emitted by <c>river_window_manager_v1.window</c>.
    /// </summary>
    public static WaylandInterop.WlInterface* RiverWindow;

    /// <summary>
    /// <c>river_decoration_v1</c> V4 — server-side decoration sub-object of a window.
    /// </summary>
    public static WaylandInterop.WlInterface* RiverDecoration;

    /// <summary>
    /// <c>river_shell_surface_v1</c> V4 — shell-surface proxy obtained via <c>get_shell_surface</c>.
    /// </summary>
    public static WaylandInterop.WlInterface* RiverShellSurface;

    /// <summary>
    /// <c>river_node_v1</c> V4 — scene-graph node attached to a window or shell-surface.
    /// </summary>
    public static WaylandInterop.WlInterface* RiverNode;

    /// <summary>
    /// <c>river_output_v1</c> V4 — per-output proxy emitted by <c>river_window_manager_v1.output</c>.
    /// </summary>
    public static WaylandInterop.WlInterface* RiverOutput;

    /// <summary>
    /// <c>river_layer_shell_v1</c> V1 — layer-shell global. Binding it tells the compositor the WM
    /// supports layer shell; it is the factory for <c>get_output</c>/<c>get_seat</c>.
    /// </summary>
    public static WaylandInterop.WlInterface* RiverLayerShell;

    /// <summary>
    /// <c>river_layer_shell_output_v1</c> V1 — per-output layer-shell state obtained via
    /// <c>river_layer_shell_v1.get_output</c>. Carries the <c>non_exclusive_area</c> event.
    /// </summary>
    public static WaylandInterop.WlInterface* RiverLayerShellOutput;

    /// <summary>
    /// <c>river_layer_shell_seat_v1</c> V1 — per-seat layer-shell state obtained via
    /// <c>river_layer_shell_v1.get_seat</c>. Carries the
    /// <c>focus_exclusive</c>/<c>focus_non_exclusive</c>/<c>focus_none</c> events.
    /// </summary>
    public static WaylandInterop.WlInterface* RiverLayerShellSeat;

    /// <summary>
    /// <c>river_seat_v1</c> V4 — per-seat proxy emitted by <c>river_window_manager_v1.seat</c>.
    /// </summary>
    public static WaylandInterop.WlInterface* RiverSeat;

    /// <summary>
    /// <c>river_pointer_binding_v1</c> V4 — pointer-button binding obtained from a
    /// <c>river_seat_v1</c>.
    /// </summary>
    public static WaylandInterop.WlInterface* RiverPointerBinding;

    /// <summary>
    /// <c>river_xkb_bindings_v1</c> V3 — keyboard binding global.
    /// </summary>
    public static WaylandInterop.WlInterface* RiverXkbBindings;

    /// <summary>
    /// <c>river_xkb_binding_v1</c> V3 — single keyboard binding entry.
    /// </summary>
    public static WaylandInterop.WlInterface* RiverXkbBinding;

    /// <summary>
    /// <c>river_xkb_config_v1</c> V2 Keyboard config bindings
    /// </summary>
    public static WaylandInterop.WlInterface* RiverXkbConfig;

    /// <summary>
    /// <c>river_xkb_config_v1</c> V2 Keymap state bindings
    /// </summary>
    public static WaylandInterop.WlInterface* RiverXkbKeymap;

    /// <summary>
    /// <c>river_xkb_config_v1</c> V2 Keyboard state bindings
    /// </summary>
    public static WaylandInterop.WlInterface* RiverXkbKeyboard;

    /// <summary>
    /// <c>river_xkb_bindings_seat_v1</c> V1 — per-seat keyboard binding context.
    /// </summary>
    public static WaylandInterop.WlInterface* RiverXkbBindingsSeat;

    // Wlr-screencopy-unstable-v1 (v3) -----------------------------------

    /// <summary>
    /// <c>wl_shm</c> V1 — shared-memory buffer factory used by the screencopy shm path.
    /// </summary>
    public static WaylandInterop.WlInterface* WlShm;

    /// <summary>
    /// <c>wl_shm_pool</c> V1 — pool created from a shm fd; produces <c>wl_buffer</c> objects.
    /// </summary>
    public static WaylandInterop.WlInterface* WlShmPool;

    /// <summary>
    /// <c>wl_buffer</c> V1 — shm buffer handed to <c>zwlr_screencopy_frame_v1.copy</c>.
    /// </summary>
    public static WaylandInterop.WlInterface* WlBuffer;

    /// <summary>
    /// <c>zwlr_screencopy_manager_v1</c> V3 — entry point of the wlr-screencopy protocol.
    /// </summary>
    public static WaylandInterop.WlInterface* ZwlrScreencopyManager;

    /// <summary>
    /// <c>zwlr_screencopy_frame_v1</c> V3 — single in-flight capture handle.
    /// </summary>
    public static WaylandInterop.WlInterface* ZwlrScreencopyFrame;

    // River_libinput_config_v1 (v2) — used to apply [input.*] from wm.toml directly to the
    // compositor's own libinput context (replaces the retired Aqueous.InputDaemon).

    /// <summary>
    /// <c>river_libinput_config_v1</c> V2 — global that announces libinput-managed devices and
    /// produces <c>river_libinput_device_v1</c> children.
    /// </summary>
    public static WaylandInterop.WlInterface* RiverLibinputConfig;

    /// <summary>
    /// <c>river_libinput_device_v1</c> V2 — per-libinput-device proxy. Accepts <c>set_accel_profile</c>,
    /// <c>set_accel_speed</c>, <c>set_natural_scroll</c>, <c>set_tap</c>, and friends.
    /// </summary>
    public static WaylandInterop.WlInterface* RiverLibinputDevice;

    /// <summary>
    /// <c>river_libinput_result_v1</c> V1 — single-shot result object returned by every
    /// <c>river_libinput_device_v1</c> setter. Destructor-on-event for all three outcomes.
    /// </summary>
    public static WaylandInterop.WlInterface* RiverLibinputResult;

    /// <summary>
    /// <c>river_input_device_v1</c> placeholder — the <c>input_device</c> event references this
    /// interface in its types[] table, but the WM does not bind <c>river_input_management_v1</c>, so
    /// only the identity (name) matters.
    /// </summary>
    public static WaylandInterop.WlInterface* RiverInputDevice;

    /// <summary>
    /// <c>river_libinput_accel_config_v1</c> V1 placeholder — referenced only as the new-id type of
    /// <c>river_libinput_config_v1.create_accel_config</c> and the <c>o</c>-arg type of
    /// <c>river_libinput_device_v1.apply_accel_config</c>; the WM never creates or destroys one.
    /// </summary>
    public static WaylandInterop.WlInterface* RiverLibinputAccelConfig;

    /// <summary>
    /// <c>ext_workspace_manager_v1</c> v1 — the workspace manager global.
    /// </summary>
    public static WaylandInterop.WlInterface* ExtWorkspaceManager;

    /// <summary>
    /// <c>ext_workspace_group_handle_v1</c> v1 — one group per output.
    /// </summary>
    public static WaylandInterop.WlInterface* ExtWorkspaceGroupHandle;

    /// <summary>
    /// <c>ext_workspace_handle_v1</c> v1 — one handle per workspace.
    /// </summary>
    public static WaylandInterop.WlInterface* ExtWorkspaceHandle;



    /// <summary>
    /// Set to <c>true</c> once <see cref="BuildAll"/> has fully populated every interface table.
    /// </summary>
    /// <remarks>
    /// Read lock-free via a fast path in <see cref="EnsureBuilt"/>; written only under <see
    /// cref="_lock"/>.
    /// </remarks>
    private static bool _built;

    /// <summary>
    /// Mutex guarding the one-time build; prevents racing initialisation from multiple threads.
    /// </summary>
    private static readonly object _lock = new();

    /// <summary>
    /// Lazily allocates the unmanaged <c>wl_interface</c> tables exactly once.
    /// </summary>
    /// <remarks>
    /// Implemented as a double-checked-locking pattern so steady-state callers pay only a single field
    /// read. This must succeed before any <see cref="WaylandInterop.wl_proxy_marshal_flags"/> call
    /// that uses one of the public <c>WlInterface*</c> fields; failure is unrecoverable — without
    /// these tables we cannot speak Wayland at all.
    /// </remarks>
    public static void EnsureBuilt()
    {
        if (_built)
        {
            return;
        }

        lock (_lock)
        {
            if (_built)
            {
                return;
            }

            BuildAll();
            _built = true;
        }
    }

    // -------- Builders ----------

    /// <summary>
    /// Pre-allocated empty <c>WlInterface*[]</c> used for messages whose signature has no typed
    /// arguments.
    /// </summary>
    /// <remarks>
    /// C# disallows pointer types as generic type arguments, so
    /// <c>Array.Empty&lt;WlInterface*&gt;()</c> is not available; we hold a single shared instance
    /// instead.
    /// </remarks>
    private static readonly WaylandInterop.WlInterface*[] NoTypes = new WaylandInterop.WlInterface*[0];

    /// <summary>
    /// Allocates a NUL-terminated UTF-8 copy of <paramref name="s"/> on the unmanaged heap and returns
    /// a pointer to it.
    /// </summary>
    /// <param name="s">
    /// String to copy.
    /// </param>
    /// <returns>
    /// Pointer to the allocated UTF-8 buffer.
    /// </returns>
    /// <remarks>
    /// The returned memory is intentionally leaked: every string produced by this helper is referenced
    /// from a <see cref="WaylandInterop.WlInterface"/> or <see cref="WaylandInterop.WlMessage"/> that
    /// lives for the entire process lifetime. Callers MUST NOT pass the result to <see
    /// cref="Marshal.FreeHGlobal"/>.
    /// </remarks>
    private static IntPtr AllocStringUtf8(string s)
    {
        var bytes = Encoding.UTF8.GetBytes(s);
        var p = Marshal.AllocHGlobal(bytes.Length + 1);
        Marshal.Copy(bytes, 0, p, bytes.Length);
        Marshal.WriteByte(p, bytes.Length, 0);
        return p;
    }

    /// <summary>
    /// Allocates a fully populated <see cref="WaylandInterop.WlInterface"/> in unmanaged memory.
    /// </summary>
    /// <param name="name">
    /// Wire-protocol interface name (e.g. <c>"wl_registry"</c>).
    /// </param>
    /// <param name="version">
    /// Interface version supported by this description.
    /// </param>
    /// <param name="requests">
    /// Request messages, indexed by opcode.
    /// </param>
    /// <param name="events">
    /// Event messages, indexed by opcode.
    /// </param>
    /// <returns>
    /// Pointer to the new interface struct (process-lifetime).
    /// </returns>
    /// <remarks>
    /// Currently unused by <see cref="BuildAll"/>, which prefers the <see cref="AllocEmpty"/> + <see
    /// cref="Populate"/> allocate-then-populate pattern so that interfaces can mutually reference each other. Kept
    /// available for callers that build standalone interfaces with no forward references.
    /// </remarks>
    private static WaylandInterop.WlInterface* AllocInterface(string name, int version, WaylandInterop.WlMessage[] requests, WaylandInterop.WlMessage[] events)
    {
        var iface = (WaylandInterop.WlInterface*)Marshal.AllocHGlobal(sizeof(WaylandInterop.WlInterface));
        iface->name = AllocStringUtf8(name);
        iface->version = version;
        iface->method_count = requests.Length;
        iface->methods = AllocMessages(requests);
        iface->event_count = events.Length;
        iface->events = AllocMessages(events);
        return iface;
    }

    /// <summary>
    /// Copies <paramref name="messages"/> into a freshly allocated, contiguous <see
    /// cref="WaylandInterop.WlMessage"/> array on the unmanaged heap.
    /// </summary>
    /// <param name="messages">
    /// Message descriptors to copy.
    /// </param>
    /// <returns>
    /// Pointer to the unmanaged array, or <see cref="IntPtr.Zero"/> when <paramref name="messages"/>
    /// is empty (libwayland accepts a null pointer for empty method/event tables).
    /// </returns>
    /// <remarks>
    /// The allocation is intentionally leaked; see <see cref="AllocStringUtf8"/>.
    /// </remarks>
    private static IntPtr AllocMessages(WaylandInterop.WlMessage[] messages)
    {
        if (messages.Length == 0)
        {
            return IntPtr.Zero;
        }

        var p = (WaylandInterop.WlMessage*)Marshal.AllocHGlobal(sizeof(WaylandInterop.WlMessage) * messages.Length);
        for (int i = 0; i < messages.Length; i++)
        {
            p[i] = messages[i];
        }

        return (IntPtr)p;
    }

    /// <summary>
    /// Builds a single <see cref="WaylandInterop.WlMessage"/> describing one request or event on the
    /// wire.
    /// </summary>
    /// <param name="name">
    /// Wire name of the message (e.g. <c>"global"</c>).
    /// </param>
    /// <param name="signature">
    /// libwayland signature string. Type codes: <c>i</c> int, <c>u</c> uint, <c>f</c> fixed, <c>s</c>
    /// string, <c>o</c> object, <c>n</c> new_id, <c>a</c> array, <c>h</c> fd. May be prefixed by a
    /// decimal "since" version (e.g. <c>"2?o"</c> = since version 2, nullable object).
    /// </param>
    /// <param name="types">
    /// Per-argument interface pointers. Length must equal the number of arguments in <paramref
    /// name="signature"/>; entries for non-object args are <c>null</c>.
    /// </param>
    /// <returns>
    /// Fully populated <see cref="WaylandInterop.WlMessage"/> value.
    /// </returns>
    private static WaylandInterop.WlMessage Msg(string name, string signature, WaylandInterop.WlInterface*[] types)
    {
        return new WaylandInterop.WlMessage
        {
            name = AllocStringUtf8(name),
            signature = AllocStringUtf8(signature),
            types = AllocTypes(types),
        };
    }

    /// <summary>
    /// Copies <paramref name="types"/> into a freshly allocated <c>wl_interface**</c> array on the
    /// unmanaged heap.
    /// </summary>
    /// <param name="types">
    /// Per-argument interface pointers.
    /// </param>
    /// <returns>
    /// Pointer to the unmanaged array, or <see cref="IntPtr.Zero"/> when <paramref name="types"/> is
    /// empty.
    /// </returns>
    /// <remarks>
    /// The allocation is intentionally leaked; see <see cref="AllocStringUtf8"/>.
    /// </remarks>
    private static IntPtr AllocTypes(WaylandInterop.WlInterface*[] types)
    {
        if (types.Length == 0)
        {
            return IntPtr.Zero;
        }

        var p = (IntPtr*)Marshal.AllocHGlobal(IntPtr.Size * types.Length);
        for (int i = 0; i < types.Length; i++)
        {
            p[i] = (IntPtr)types[i];
        }

        return (IntPtr)p;
    }

    // -------- Build graph ---------- Interfaces reference each other (e.g. manager's "toplevel"
    // event yields a new_id<handle>) so we allocate the structs first and then populate their message
    // tables. This mirrors how wayland-scanner emits C code with forward declarations.

    /// <summary>
    /// Builds every <see cref="WaylandInterop.WlInterface"/> consumed by the rest of the codebase.
    /// </summary>
    /// <remarks>
    /// Interfaces reference each other (e.g. the manager's <c>toplevel</c> event yields a
    /// <c>new_id&lt;handle&gt;</c>) so the function first uses <see cref="AllocEmpty"/> to
    /// reserve storage for every interface, then <see cref="Populate"/> fills in the message tables.
    /// This mirrors how wayland-scanner emits C with forward declarations.
    /// <para>
    /// Layout:
    /// <list type="bullet">
    /// <item>
    /// <c>wl_registry</c> — bind / global / global_remove.
    /// </item>
    /// <item>
    /// <c>wl_seat</c>, <c>wl_surface</c>, <c>wl_output</c> — identity-only placeholders.
    /// </item>
    /// <item>
    /// <c>zwlr_foreign_toplevel_manager_v1</c> v3 + <c>zwlr_foreign_toplevel_handle_v1</c> v3.
    /// </item>
    /// <item>
    /// The full <c>river_window_management_v1</c> v4 graph (delegated to <see
    /// cref="BuildRiverWindowManagement"/>).
    /// </item>
    /// </list>
    /// </para>
    /// </remarks>
    private static void BuildAll()
    {
        // 1. Allocate empty interface structs so later messages can point at them.
        WlRegistry = AllocEmpty("wl_registry", 1);
        WlSeat = AllocEmpty("wl_seat", 7);
        WlSurface = AllocEmpty("wl_surface", 1);
        WlOutput = AllocEmpty("wl_output", 4);
        ZwlrManager = AllocEmpty("zwlr_foreign_toplevel_manager_v1", 3);
        ZwlrHandle = AllocEmpty("zwlr_foreign_toplevel_handle_v1", 3);
        RiverLayerShell = AllocEmpty("river_layer_shell_v1", 1);

        // 2. wl_registry request 0: bind(name: uint, id: new_id<?>) — untyped new_id = "sun" prefix event
        // 0: global(name: uint, interface: string, version: uint) event 1: global_remove(name: uint)
        Populate(WlRegistry,
            requests: new[]
            {
                Msg("bind", "usun", new WaylandInterop.WlInterface*[] { null, null, null, null }),
            },
            events: new[]
            {
                Msg("global", "usu", new WaylandInterop.WlInterface*[] { null, null, null }),
                Msg("global_remove", "u", new WaylandInterop.WlInterface*[] { null }),
            });

        // 3. wl_seat — we never send requests; skip methods. Events list can be empty since we never
        // attach a dispatcher to the seat.
        Populate(WlSeat, requests: Array.Empty<WaylandInterop.WlMessage>(), events: Array.Empty<WaylandInterop.WlMessage>());

        // 4. wl_surface / wl_output — only the name matters; messages are unused (we never create these
        // ourselves and never interpret their events).
        Populate(WlSurface, Array.Empty<WaylandInterop.WlMessage>(), Array.Empty<WaylandInterop.WlMessage>());

        // Wl_output (version 4) request 0: release [since v3, destructor] events: 0 geometry(int x, int
        // y, int phys_w, int phys_h, int subpixel, string make, string model, int transform) 1 mode(uint
        // flags, int width, int height, int refresh) 2 done [since v2] 3 scale(int factor) [since v2] 4
        // name(string) [since v4] 5 description(string) [since v4] We don't consume any of these, but the
        // descriptor MUST list them so libwayland's dispatcher can route the events without raising a
        // protocol error and tearing down the connection.
        Populate(WlOutput,
            requests: new[]
            {
                Msg("release", "3", NoTypes),
            },
            events: new[]
            {
                Msg("geometry",    "iiiiissi", new WaylandInterop.WlInterface*[] { null, null, null, null, null, null, null, null }),
                Msg("mode",        "uiii",     new WaylandInterop.WlInterface*[] { null, null, null, null }),
                Msg("done",        "2",        NoTypes),
                Msg("scale",       "2i",       new WaylandInterop.WlInterface*[] { null }),
                Msg("name",        "4s",       new WaylandInterop.WlInterface*[] { null }),
                Msg("description", "4s",       new WaylandInterop.WlInterface*[] { null }),
            });

        // 5. zwlr_foreign_toplevel_manager_v1 (version 3) request 0: stop event 0:
        // toplevel(new_id<handle>) event 1: finished
        Populate(ZwlrManager,
            requests: new[]
            {
                Msg("stop", "", NoTypes),
            },
            events: new[]
            {
                Msg("toplevel", "n", new WaylandInterop.WlInterface*[] { ZwlrHandle }),
                Msg("finished", "", NoTypes),
            });

        // 6. zwlr_foreign_toplevel_handle_v1 (version 3) requests (as per wayland-protocols XML): 0
        // set_maximized 1 unset_maximized 2 set_minimized 3 unset_minimized 4 activate(wl_seat) 5 close 6
        // set_rectangle(wl_surface, int, int, int, int) 7 destroy [destructor] 8
        // set_fullscreen(?wl_output) [since v2] 9 unset_fullscreen [since v2] events: 0 title(string) 1
        // app_id(string) 2 output_enter(object<wl_output>) 3 output_leave(object<wl_output>) 4
        // state(array) 5 done 6 closed 7 parent(?object<handle>) [since v3]
        Populate(ZwlrHandle,
            requests: new[]
            {
                Msg("set_maximized",   "",      NoTypes),
                Msg("unset_maximized", "",      NoTypes),
                Msg("set_minimized",   "",      NoTypes),
                Msg("unset_minimized", "",      NoTypes),
                Msg("activate",        "o",     new WaylandInterop.WlInterface*[] { WlSeat }),
                Msg("close",           "",      NoTypes),
                Msg("set_rectangle",   "oiiii", new WaylandInterop.WlInterface*[] { WlSurface, null, null, null, null }),
                Msg("destroy",         "",      NoTypes),
                Msg("set_fullscreen",  "2?o",   new WaylandInterop.WlInterface*[] { WlOutput }),
                Msg("unset_fullscreen","2",     NoTypes),
            },
            events: new[]
            {
                Msg("title",        "s",  new WaylandInterop.WlInterface*[] { null }),
                Msg("app_id",       "s",  new WaylandInterop.WlInterface*[] { null }),
                Msg("output_enter", "o",  new WaylandInterop.WlInterface*[] { WlOutput }),
                Msg("output_leave", "o",  new WaylandInterop.WlInterface*[] { WlOutput }),
                Msg("state",        "a",  new WaylandInterop.WlInterface*[] { null }),
                Msg("done",         "",   NoTypes),
                Msg("closed",       "",   NoTypes),
                Msg("parent",       "3?o", new WaylandInterop.WlInterface*[] { ZwlrHandle }),
            });

        BuildExtWorkspace();
        BuildRiverWindowManagement();
        BuildWlrScreencopy();
        BuildRiverLibinputConfig();
        BuildRiverXkbConfig();
    }

    // -------- ext_workspace_v1 (v1) ----------

    /// <summary>
    /// Builds the <c>ext-workspace-v1</c> interface graph (manager + group handle + workspace
    /// handle). Signatures and opcodes are taken verbatim from the vendored
    /// <c>ext-workspace-v1.xml</c>. Built before <see cref="BuildRiverWindowManagement"/> so that
    /// <c>river_window_v1.set_workspace</c> can reference <see cref="ExtWorkspaceHandle"/>.
    /// </summary>
    private static void BuildExtWorkspace()
    {
        ExtWorkspaceManager = AllocEmpty("ext_workspace_manager_v1", 1);
        ExtWorkspaceGroupHandle = AllocEmpty("ext_workspace_group_handle_v1", 1);
        ExtWorkspaceHandle = AllocEmpty("ext_workspace_handle_v1", 1);

        Populate(ExtWorkspaceManager,
            requests: new[]
            {
                Msg("commit", "", NoTypes),
                Msg("stop",   "", NoTypes),
            },
            events: new[]
            {
                Msg("workspace_group", "n", new WaylandInterop.WlInterface*[] { ExtWorkspaceGroupHandle }),
                Msg("workspace",       "n", new WaylandInterop.WlInterface*[] { ExtWorkspaceHandle }),
                Msg("done",            "",  NoTypes),
                Msg("finished",        "",  NoTypes),
            });

        Populate(ExtWorkspaceGroupHandle,
            requests: new[]
            {
                Msg("create_workspace", "s", new WaylandInterop.WlInterface*[] { null }),
                Msg("destroy",          "",  NoTypes),
            },
            events: new[]
            {
                Msg("capabilities",    "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("output_enter",    "o", new WaylandInterop.WlInterface*[] { WlOutput }),
                Msg("output_leave",    "o", new WaylandInterop.WlInterface*[] { WlOutput }),
                Msg("workspace_enter", "o", new WaylandInterop.WlInterface*[] { ExtWorkspaceHandle }),
                Msg("workspace_leave", "o", new WaylandInterop.WlInterface*[] { ExtWorkspaceHandle }),
                Msg("removed",         "",  NoTypes),
            });

        Populate(ExtWorkspaceHandle,
            requests: new[]
            {
                Msg("destroy",    "", NoTypes),
                Msg("activate",   "", NoTypes),
                Msg("deactivate", "", NoTypes),
                Msg("assign",     "o", new WaylandInterop.WlInterface*[] { ExtWorkspaceGroupHandle }),
                Msg("remove",     "", NoTypes),
            },
            events: new[]
            {
                Msg("id",           "s", new WaylandInterop.WlInterface*[] { null }),
                Msg("name",         "s", new WaylandInterop.WlInterface*[] { null }),
                Msg("coordinates",  "a", new WaylandInterop.WlInterface*[] { null }),
                Msg("state",        "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("capabilities", "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("removed",      "",  NoTypes),
            });
    }

    // -------- River_libinput_config_v1 (v2) ----------

    /// <summary>
    /// Builds the <c>river_libinput_config_v1</c> v2 graph (config global + per-device proxy + result
    /// object + accel-config placeholder + input_device placeholder). Used by
    /// <c>LibinputConfigApplier</c> to push <c>[input.*]</c> from <c>wm.toml</c> straight into the
    /// compositor's libinput context — the same context that produces the deltas fed into
    /// <c>Cursor.processMotionRelative</c>.
    /// </summary>
    /// <remarks>
    /// Signatures and opcodes are extracted verbatim from
    /// <c>compositor/protocol/river-libinput-config-v1.xml</c>. The <c>accel_speed</c> argument is
    /// transported as a libwayland <c>array</c> of one native-endian IEEE-754 <c>double</c> (the
    /// protocol's documented convention for floating-point values). Requests we never send
    /// (<c>set_tap_button_map</c>, <c>set_drag</c>, <c>set_calibration_matrix</c>, …) are still
    /// declared so the message table matches v2 and libwayland's opcode arithmetic stays sound.
    /// </remarks>
    private static void BuildRiverLibinputConfig()
    {
        RiverLibinputConfig = AllocEmpty("river_libinput_config_v1", 2);
        RiverLibinputDevice = AllocEmpty("river_libinput_device_v1", 2);
        RiverLibinputResult = AllocEmpty("river_libinput_result_v1", 1);
        RiverLibinputAccelConfig = AllocEmpty("river_libinput_accel_config_v1", 1);
        RiverInputDevice = AllocEmpty("river_input_device_v1", 1);

        // River_input_device_v1: identity-only placeholder (we never receive events on it).
        Populate(RiverInputDevice, Array.Empty<WaylandInterop.WlMessage>(), Array.Empty<WaylandInterop.WlMessage>());

        // River_libinput_accel_config_v1: identity-only placeholder; the WM never creates one in
        // this minimal client (set_accel_speed is sufficient for the mouse/touchpad parity we need).
        Populate(RiverLibinputAccelConfig,
            requests: new[]
            {
                Msg("destroy",   "",   NoTypes),
                Msg("set_points","uaa", new WaylandInterop.WlInterface*[] { null, null, null }),
            },
            events: Array.Empty<WaylandInterop.WlMessage>());

        // River_libinput_result_v1 — three destructor events; no requests.
        Populate(RiverLibinputResult,
            requests: Array.Empty<WaylandInterop.WlMessage>(),
            events: new[]
            {
                Msg("success",     "", NoTypes),
                Msg("unsupported", "", NoTypes),
                Msg("invalid",     "", NoTypes),
            });

        // River_libinput_config_v1 requests: 0 stop, 1 destroy, 2 create_accel_config(new_id, profile)
        // events: 0 finished, 1 libinput_device(new_id<device>)
        Populate(RiverLibinputConfig,
            requests: new[]
            {
                Msg("stop",                "",  NoTypes),
                Msg("destroy",             "",  NoTypes),
                Msg("create_accel_config", "nu", new WaylandInterop.WlInterface*[] { RiverLibinputAccelConfig, null }),
            },
            events: new[]
            {
                Msg("finished",        "",  NoTypes),
                Msg("libinput_device", "n", new WaylandInterop.WlInterface*[] { RiverLibinputDevice }),
            });

        // River_libinput_device_v1 — verbatim from XML order.
        Populate(RiverLibinputDevice,
            requests: new[]
            {
                Msg("destroy",                  "",   NoTypes),
                Msg("set_send_events",          "nu", new WaylandInterop.WlInterface*[] { RiverLibinputResult, null }),
                Msg("set_tap",                  "nu", new WaylandInterop.WlInterface*[] { RiverLibinputResult, null }),
                Msg("set_tap_button_map",       "nu", new WaylandInterop.WlInterface*[] { RiverLibinputResult, null }),
                Msg("set_drag",                 "nu", new WaylandInterop.WlInterface*[] { RiverLibinputResult, null }),
                Msg("set_drag_lock",            "nu", new WaylandInterop.WlInterface*[] { RiverLibinputResult, null }),
                Msg("set_three_finger_drag",    "nu", new WaylandInterop.WlInterface*[] { RiverLibinputResult, null }),
                Msg("set_calibration_matrix",   "na", new WaylandInterop.WlInterface*[] { RiverLibinputResult, null }),
                Msg("set_accel_profile",        "nu", new WaylandInterop.WlInterface*[] { RiverLibinputResult, null }),
                Msg("set_accel_speed",          "na", new WaylandInterop.WlInterface*[] { RiverLibinputResult, null }),
                Msg("apply_accel_config",       "no", new WaylandInterop.WlInterface*[] { RiverLibinputResult, RiverLibinputAccelConfig }),
                Msg("set_natural_scroll",       "nu", new WaylandInterop.WlInterface*[] { RiverLibinputResult, null }),
                Msg("set_left_handed",          "nu", new WaylandInterop.WlInterface*[] { RiverLibinputResult, null }),
                Msg("set_click_method",         "nu", new WaylandInterop.WlInterface*[] { RiverLibinputResult, null }),
                Msg("set_clickfinger_button_map","nu",new WaylandInterop.WlInterface*[] { RiverLibinputResult, null }),
                Msg("set_middle_emulation",     "nu", new WaylandInterop.WlInterface*[] { RiverLibinputResult, null }),
                Msg("set_scroll_method",        "nu", new WaylandInterop.WlInterface*[] { RiverLibinputResult, null }),
                Msg("set_scroll_button",        "nu", new WaylandInterop.WlInterface*[] { RiverLibinputResult, null }),
                Msg("set_scroll_button_lock",   "nu", new WaylandInterop.WlInterface*[] { RiverLibinputResult, null }),
                Msg("set_dwt",                  "nu", new WaylandInterop.WlInterface*[] { RiverLibinputResult, null }),
                Msg("set_dwtp",                 "nu", new WaylandInterop.WlInterface*[] { RiverLibinputResult, null }),
                Msg("set_rotation",             "nu", new WaylandInterop.WlInterface*[] { RiverLibinputResult, null }),
            },
            events: new[]
            {
                Msg("removed",                       "",  NoTypes),
                Msg("input_device",                  "o", new WaylandInterop.WlInterface*[] { RiverInputDevice }),
                Msg("send_events_support",           "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("send_events_default",           "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("send_events_current",           "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("tap_support",                   "i", new WaylandInterop.WlInterface*[] { null }),
                Msg("tap_default",                   "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("tap_current",                   "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("tap_button_map_default",        "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("tap_button_map_current",        "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("drag_default",                  "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("drag_current",                  "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("drag_lock_default",             "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("drag_lock_current",             "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("three_finger_drag_support",     "i", new WaylandInterop.WlInterface*[] { null }),
                Msg("three_finger_drag_default",     "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("three_finger_drag_current",     "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("calibration_matrix_support",    "i", new WaylandInterop.WlInterface*[] { null }),
                Msg("calibration_matrix_default",    "a", new WaylandInterop.WlInterface*[] { null }),
                Msg("calibration_matrix_current",    "a", new WaylandInterop.WlInterface*[] { null }),
                Msg("accel_profiles_support",        "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("accel_profile_default",         "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("accel_profile_current",         "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("accel_speed_default",           "a", new WaylandInterop.WlInterface*[] { null }),
                Msg("accel_speed_current",           "a", new WaylandInterop.WlInterface*[] { null }),
                Msg("natural_scroll_support",        "i", new WaylandInterop.WlInterface*[] { null }),
                Msg("natural_scroll_default",        "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("natural_scroll_current",        "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("left_handed_support",           "i", new WaylandInterop.WlInterface*[] { null }),
                Msg("left_handed_default",           "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("left_handed_current",           "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("click_method_support",          "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("click_method_default",          "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("click_method_current",          "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("clickfinger_button_map_default","u", new WaylandInterop.WlInterface*[] { null }),
                Msg("clickfinger_button_map_current","u", new WaylandInterop.WlInterface*[] { null }),
                Msg("middle_emulation_support",      "i", new WaylandInterop.WlInterface*[] { null }),
                Msg("middle_emulation_default",      "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("middle_emulation_current",      "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("scroll_method_support",         "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("scroll_method_default",         "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("scroll_method_current",         "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("scroll_button_default",         "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("scroll_button_current",         "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("scroll_button_lock_default",    "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("scroll_button_lock_current",    "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("dwt_support",                   "i", new WaylandInterop.WlInterface*[] { null }),
                Msg("dwt_default",                   "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("dwt_current",                   "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("dwtp_support",                  "i", new WaylandInterop.WlInterface*[] { null }),
                Msg("dwtp_default",                  "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("dwtp_current",                  "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("rotation_support",              "i", new WaylandInterop.WlInterface*[] { null }),
                Msg("rotation_default",              "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("rotation_current",              "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("done",                          "2", NoTypes),
            });
    }

    // -------- River_xkb_config_v1 (v2) ----------

    /// <summary>
    /// Builds the <c>river_xkb_config_v1</c> / <c>river_xkb_keymap_v1</c> / <c>river_xkb_keyboard_v1</c>
    /// interface graph from <c>compositor/protocol/river-xkb-config-v1.xml</c>. Used to compile an
    /// xkbcommon keymap from <c>[input] xkb_*</c> in <c>wm.toml</c> and push it to every keyboard
    /// device the compositor announces (see <c>XkbConfigApplier</c>).
    /// </summary>
    /// <remarks>
    /// Built after <see cref="BuildRiverLibinputConfig"/> so the <c>input_device</c> event of
    /// <c>river_xkb_keyboard_v1</c> can reference <see cref="RiverInputDevice"/> (allocated there).
    /// Opcodes/signatures are taken verbatim from the XML; every request and event is declared so
    /// libwayland's opcode arithmetic stays sound even for messages we never send/inspect.
    /// </remarks>
    private static void BuildRiverXkbConfig()
    {
        RiverXkbConfig   = AllocEmpty("river_xkb_config_v1", 2);
        RiverXkbKeymap   = AllocEmpty("river_xkb_keymap_v1", 2);
        RiverXkbKeyboard = AllocEmpty("river_xkb_keyboard_v1", 2);

        // river_xkb_config_v1 requests: 0 stop, 1 destroy, 2 create_keymap(new_id, fd, format)
        // events: 0 finished, 1 xkb_keyboard(new_id<river_xkb_keyboard_v1>)
        Populate(RiverXkbConfig,
            requests: new[]
            {
                Msg("stop",          "",    NoTypes),
                Msg("destroy",       "",    NoTypes),
                Msg("create_keymap", "nhu", new WaylandInterop.WlInterface*[] { RiverXkbKeymap, null, null }),
            },
            events: new[]
            {
                Msg("finished",     "",  NoTypes),
                Msg("xkb_keyboard", "n", new WaylandInterop.WlInterface*[] { RiverXkbKeyboard }),
            });

        // river_xkb_keymap_v1 requests: 0 destroy events: 0 success, 1 failure(string)
        Populate(RiverXkbKeymap,
            requests: new[]
            {
                Msg("destroy", "", NoTypes),
            },
            events: new[]
            {
                Msg("success", "",  NoTypes),
                Msg("failure", "s", new WaylandInterop.WlInterface*[] { null }),
            });

        // river_xkb_keyboard_v1 requests: 0 destroy, 1 set_keymap(object<keymap>), 2 set_layout_by_index(int),
        // 3 set_layout_by_name(string), 4 capslock_enable, 5 capslock_disable, 6 numlock_enable, 7 numlock_disable
        // events: 0 removed, 1 input_device(object<river_input_device_v1>), 2 layout(uint, string), 3
        // capslock_enabled, 4 capslock_disabled, 5 numlock_enabled, 6 numlock_disabled, 7 done [since v2]
        Populate(RiverXkbKeyboard,
            requests: new[]
            {
                Msg("destroy",             "",  NoTypes),
                Msg("set_keymap",          "o", new WaylandInterop.WlInterface*[] { RiverXkbKeymap }),
                Msg("set_layout_by_index", "i", new WaylandInterop.WlInterface*[] { null }),
                Msg("set_layout_by_name",  "s", new WaylandInterop.WlInterface*[] { null }),
                Msg("capslock_enable",     "",  NoTypes),
                Msg("capslock_disable",    "",  NoTypes),
                Msg("numlock_enable",      "",  NoTypes),
                Msg("numlock_disable",     "",  NoTypes),
            },
            events: new[]
            {
                Msg("removed",           "",   NoTypes),
                Msg("input_device",      "o",  new WaylandInterop.WlInterface*[] { RiverInputDevice }),
                Msg("layout",            "us", new WaylandInterop.WlInterface*[] { null, null }),
                Msg("capslock_enabled",  "",   NoTypes),
                Msg("capslock_disabled", "",   NoTypes),
                Msg("numlock_enabled",   "",   NoTypes),
                Msg("numlock_disabled",  "",   NoTypes),
                Msg("done",              "2",  NoTypes),
            });
    }

    // -------- Wlr-screencopy-unstable-v1 (v3) ----------

    /// <summary>
    /// Builds the <c>wl_shm</c> / <c>wl_shm_pool</c> / <c>wl_buffer</c> trio and the two
    /// <c>zwlr_screencopy_*</c> interfaces from <c>Protocols/wlr-screencopy-unstable-v1.xml</c>.
    /// </summary>
    /// <remarks>
    /// Signatures and opcodes are extracted verbatim from the upstream wlr-protocols XML. The shm trio
    /// carries only the requests and events this client actually invokes (create_pool, create_buffer,
    /// destroy requests on the manager-side; release event on wl_buffer).
    /// </remarks>
    private static void BuildWlrScreencopy()
    {
        WlShm                  = AllocEmpty("wl_shm", 1);
        WlShmPool              = AllocEmpty("wl_shm_pool", 1);
        WlBuffer               = AllocEmpty("wl_buffer", 1);
        ZwlrScreencopyManager  = AllocEmpty("zwlr_screencopy_manager_v1", 3);
        ZwlrScreencopyFrame    = AllocEmpty("zwlr_screencopy_frame_v1", 3);

        // Wl_shm request 0: create_pool(new_id<wl_shm_pool>, fd, size) event 0: format(uint)
        Populate(WlShm,
            requests: new[]
            {
                Msg("create_pool", "nhi", new WaylandInterop.WlInterface*[] { WlShmPool, null, null }),
            },
            events: new[]
            {
                Msg("format", "u", new WaylandInterop.WlInterface*[] { null }),
            });

        // Wl_shm_pool request 0: create_buffer(new_id<wl_buffer>, offset, width, height, stride, format)
        // request 1: destroy [destructor] request 2: resize(size)
        Populate(WlShmPool,
            requests: new[]
            {
                Msg("create_buffer", "niiiiu", new WaylandInterop.WlInterface*[] { WlBuffer, null, null, null, null, null }),
                Msg("destroy",       "",      NoTypes),
                Msg("resize",        "i",     new WaylandInterop.WlInterface*[] { null }),
            },
            events: Array.Empty<WaylandInterop.WlMessage>());

        // Wl_buffer request 0: destroy [destructor] event 0: release
        Populate(WlBuffer,
            requests: new[]
            {
                Msg("destroy", "", NoTypes),
            },
            events: new[]
            {
                Msg("release", "", NoTypes),
            });

        // Zwlr_screencopy_manager_v1 (version 3) request 0: capture_output(new_id<frame>, int
        // overlay_cursor, object<wl_output>) request 1: capture_output_region(new_id<frame>, int
        // overlay_cursor, object<wl_output>, int x, int y, int width, int height) request 2: destroy
        // [destructor]
        Populate(ZwlrScreencopyManager,
            requests: new[]
            {
                Msg("capture_output",        "nio",      new WaylandInterop.WlInterface*[] { ZwlrScreencopyFrame, null, WlOutput }),
                Msg("capture_output_region", "nioiiii",  new WaylandInterop.WlInterface*[] { ZwlrScreencopyFrame, null, WlOutput, null, null, null, null }),
                Msg("destroy",               "",         NoTypes),
            },
            events: Array.Empty<WaylandInterop.WlMessage>());

        // Zwlr_screencopy_frame_v1 (version 3) requests: 0 copy(object<wl_buffer>) 1 destroy [destructor]
        // 2 copy_with_damage(object<wl_buffer>) events: 0 buffer(uint format, uint width, uint height,
        // uint stride) 1 flags(uint flags) 2 ready(uint tv_sec_hi, uint tv_sec_lo, uint tv_nsec) 3 failed
        // 4 damage(uint x, uint y, uint width, uint height) [since v2] 5 linux_dmabuf(uint format, uint
        // width, uint height) [since v3] 6 buffer_done [since v3]
        Populate(ZwlrScreencopyFrame,
            requests: new[]
            {
                Msg("copy",              "o",  new WaylandInterop.WlInterface*[] { WlBuffer }),
                Msg("destroy",           "",   NoTypes),
                Msg("copy_with_damage",  "o",  new WaylandInterop.WlInterface*[] { WlBuffer }),
            },
            events: new[]
            {
                Msg("buffer",        "uuuu",  new WaylandInterop.WlInterface*[] { null, null, null, null }),
                Msg("flags",         "u",     new WaylandInterop.WlInterface*[] { null }),
                Msg("ready",         "uuu",   new WaylandInterop.WlInterface*[] { null, null, null }),
                Msg("failed",        "",      NoTypes),
                Msg("damage",        "2uuuu", new WaylandInterop.WlInterface*[] { null, null, null, null }),
                Msg("linux_dmabuf",  "3uuu",  new WaylandInterop.WlInterface*[] { null, null, null }),
                Msg("buffer_done",   "3",     NoTypes),
            });
    }

    // -------- River_window_management_v1 (v4) ----------

    /// <summary>
    /// Builds the <c>river_window_management_v1</c> v4 interface graph.
    /// </summary>
    /// <remarks>
    /// Signatures and opcodes are extracted verbatim from
    /// <c>/usr/share/river-protocols/stable/river-window-management-v1.xml</c> (helper script
    /// <c>/tmp/extract_sigs.py</c>). Every request and event is declared with its exact signature
    /// string and nested interface pointers so libwayland-client can marshal the wire protocol.
    /// <para>
    /// Note: the leading decimal "since" digits in some signatures (e.g. <c>"2iiii"</c>) are valid per
    /// libwayland's <c>wl_message::signature</c> docs and gate availability on the interface version.
    /// Because we always bind the manager at version 4 and every gated message exists by then, the
    /// prefixes are harmless.
    /// </para>
    /// </remarks>
    private static void BuildRiverWindowManagement()
    {
        RiverWindowManager = AllocEmpty("river_window_manager_v1", 6);
        RiverWindow = AllocEmpty("river_window_v1", 6);
        RiverDecoration = AllocEmpty("river_decoration_v1", 4);
        RiverShellSurface = AllocEmpty("river_shell_surface_v1", 5);
        RiverNode = AllocEmpty("river_node_v1", 4);
        RiverOutput = AllocEmpty("river_output_v1", 4);
        RiverLayerShell = AllocEmpty("river_layer_shell_v1", 1);
        RiverLayerShellOutput = AllocEmpty("river_layer_shell_output_v1", 1);
        RiverLayerShellSeat = AllocEmpty("river_layer_shell_seat_v1", 1);
        RiverSeat = AllocEmpty("river_seat_v1", 4);
        RiverPointerBinding = AllocEmpty("river_pointer_binding_v1", 4);
        RiverXkbBindings = AllocEmpty("river_xkb_bindings_v1", 3);
        RiverXkbBinding = AllocEmpty("river_xkb_binding_v1", 3);
        RiverXkbBindingsSeat = AllocEmpty("river_xkb_bindings_seat_v1", 1);

        // River_window_manager_v1
        Populate(RiverWindowManager,
            requests: new[]
            {
                Msg("stop",              "",   NoTypes),
                Msg("destroy",           "",   NoTypes),
                Msg("manage_finish",     "",   NoTypes),
                Msg("manage_dirty",      "",   NoTypes),
                Msg("render_finish",     "",   NoTypes),
                Msg("get_shell_surface", "no", new WaylandInterop.WlInterface*[] { RiverShellSurface, WlSurface }),
                Msg("exit_session",      "4",  NoTypes),
            },
            events: new[]
            {
                Msg("unavailable",       "",   NoTypes),
                Msg("finished",          "",   NoTypes),
                Msg("manage_start",      "",   NoTypes),
                Msg("render_start",      "",   NoTypes),
                Msg("session_locked",    "",   NoTypes),
                Msg("session_unlocked",  "",   NoTypes),
                Msg("window",            "n",  new WaylandInterop.WlInterface*[] { RiverWindow }),
                Msg("output",            "n",  new WaylandInterop.WlInterface*[] { RiverOutput }),
                Msg("seat",              "n",  new WaylandInterop.WlInterface*[] { RiverSeat }),
            });

        // River_window_v1
        Populate(RiverWindow,
            requests: new[]
            {
                Msg("destroy",              "",        NoTypes),
                Msg("close",                "",        NoTypes),
                Msg("get_node",             "n",       new WaylandInterop.WlInterface*[] { RiverNode }),
                Msg("propose_dimensions",   "ii",      new WaylandInterop.WlInterface*[] { null, null }),
                Msg("hide",                 "",        NoTypes),
                Msg("show",                 "",        NoTypes),
                Msg("use_csd",              "",        NoTypes),
                Msg("use_ssd",              "",        NoTypes),
                Msg("set_borders",          "uiuuuu",  new WaylandInterop.WlInterface*[] { null, null, null, null, null, null }),
                Msg("set_tiled",            "u",       new WaylandInterop.WlInterface*[] { null }),
                Msg("get_decoration_above", "no",      new WaylandInterop.WlInterface*[] { RiverDecoration, WlSurface }),
                Msg("get_decoration_below", "no",      new WaylandInterop.WlInterface*[] { RiverDecoration, WlSurface }),
                Msg("inform_resize_start",  "",        NoTypes),
                Msg("inform_resize_end",    "",        NoTypes),
                Msg("set_capabilities",     "u",       new WaylandInterop.WlInterface*[] { null }),
                Msg("inform_maximized",     "",        NoTypes),
                Msg("inform_unmaximized",   "",        NoTypes),
                Msg("inform_fullscreen",    "",        NoTypes),
                Msg("inform_not_fullscreen","",        NoTypes),
                Msg("fullscreen",           "o",       new WaylandInterop.WlInterface*[] { RiverOutput }),
                Msg("exit_fullscreen",      "",        NoTypes),
                Msg("set_clip_box",         "2iiii",   new WaylandInterop.WlInterface*[] { null, null, null, null }),
                Msg("set_content_clip_box", "3iiii",   new WaylandInterop.WlInterface*[] { null, null, null, null }),
                Msg("set_dimension_bounds", "4ii",     new WaylandInterop.WlInterface*[] { null, null }),
                Msg("set_workspace",        "6o",      new WaylandInterop.WlInterface*[] { ExtWorkspaceHandle }),
            },
            events: new[]
            {
                Msg("closed",                    "",     NoTypes),
                Msg("dimensions_hint",           "iiii", new WaylandInterop.WlInterface*[] { null, null, null, null }),
                Msg("dimensions",                "ii",   new WaylandInterop.WlInterface*[] { null, null }),
                Msg("app_id",                    "?s",   new WaylandInterop.WlInterface*[] { null }),
                Msg("title",                     "?s",   new WaylandInterop.WlInterface*[] { null }),
                Msg("parent",                    "?o",   new WaylandInterop.WlInterface*[] { RiverWindow }),
                Msg("decoration_hint",           "u",    new WaylandInterop.WlInterface*[] { null }),
                Msg("pointer_move_requested",    "o",    new WaylandInterop.WlInterface*[] { RiverSeat }),
                Msg("pointer_resize_requested",  "ou",   new WaylandInterop.WlInterface*[] { RiverSeat, null }),
                Msg("show_window_menu_requested","ii",   new WaylandInterop.WlInterface*[] { null, null }),
                Msg("maximize_requested",        "",     NoTypes),
                Msg("unmaximize_requested",      "",     NoTypes),
                Msg("fullscreen_requested",      "?o",   new WaylandInterop.WlInterface*[] { RiverOutput }),
                Msg("exit_fullscreen_requested", "",     NoTypes),
                Msg("minimize_requested",        "",     NoTypes),
                Msg("unreliable_pid",            "2i",   new WaylandInterop.WlInterface*[] { null }),
                Msg("presentation_hint",         "4u",   new WaylandInterop.WlInterface*[] { null }),
                Msg("identifier",                "4s",   new WaylandInterop.WlInterface*[] { null }),
                Msg("activate_requested",        "5",    NoTypes),
                Msg("unminimize_requested",      "5",    NoTypes),
            });

        // River_decoration_v1
        Populate(RiverDecoration,
            requests: new[]
            {
                Msg("destroy",          "",   NoTypes),
                Msg("set_offset",       "ii", new WaylandInterop.WlInterface*[] { null, null }),
                Msg("sync_next_commit", "",   NoTypes),
            },
            events: Array.Empty<WaylandInterop.WlMessage>());

        // River_shell_surface_v1
        Populate(RiverShellSurface,
            requests: new[]
            {
                Msg("destroy",          "",  NoTypes),
                Msg("get_node",         "n", new WaylandInterop.WlInterface*[] { RiverNode }),
                Msg("sync_next_commit", "",  NoTypes),
            },
            events: new[]
            {
                // Opcode 0: destroyed (since v5). Sent when the shell-surface object becomes
                // invalid server-side so the WM can drop pending focus before marshaling on a
                // freed proxy (the "segfault at 2c" crash).
                Msg("destroyed", "5", NoTypes),
            });

        // River_layer_shell_v1 (new shape) — requests only, no events.
        // Request opcodes follow XML declaration order: destroy=0, get_output=1, get_seat=2.
        Populate(RiverLayerShell,
            requests: new[]
            {
                Msg("destroy",    "",  NoTypes),
                Msg("get_output", "no", new WaylandInterop.WlInterface*[] { RiverLayerShellOutput, RiverOutput }),
                Msg("get_seat",   "no", new WaylandInterop.WlInterface*[] { RiverLayerShellSeat,   RiverSeat   }),
            },
            events: Array.Empty<WaylandInterop.WlMessage>());

        // River_layer_shell_output_v1 — request opcodes: destroy=0, set_default=1.
        // Event opcode: non_exclusive_area=0 (request/event opcodes are numbered independently).
        // set_default may only be sent inside a manage sequence.
        Populate(RiverLayerShellOutput,
            requests: new[]
            {
                Msg("destroy",     "", NoTypes),
                Msg("set_default", "", NoTypes),
            },
            events: new[]
            {
                Msg("non_exclusive_area", "iiii", new WaylandInterop.WlInterface*[] { null, null, null, null }),
            });

        // River_layer_shell_seat_v1 — request opcode: destroy=0.
        // Event opcodes: focus_exclusive=0, focus_non_exclusive=1, focus_none=2 (all no-arg).
        Populate(RiverLayerShellSeat,
            requests: new[]
            {
                Msg("destroy", "", NoTypes),
            },
            events: new[]
            {
                Msg("focus_exclusive",     "", NoTypes),
                Msg("focus_non_exclusive", "", NoTypes),
                Msg("focus_none",          "", NoTypes),
            });

        // River_node_v1
        Populate(RiverNode,
            requests: new[]
            {
                Msg("destroy",      "",   NoTypes),
                Msg("set_position", "ii", new WaylandInterop.WlInterface*[] { null, null }),
                Msg("place_top",    "",   NoTypes),
                Msg("place_bottom", "",   NoTypes),
                Msg("place_above",  "o",  new WaylandInterop.WlInterface*[] { RiverNode }),
                Msg("place_below",  "o",  new WaylandInterop.WlInterface*[] { RiverNode }),
            },
            events: Array.Empty<WaylandInterop.WlMessage>());

        // River_output_v1
        Populate(RiverOutput,
            requests: new[]
            {
                Msg("destroy",               "",   NoTypes),
                Msg("set_presentation_mode", "4u", new WaylandInterop.WlInterface*[] { null }),
            },
            events: new[]
            {
                Msg("removed",    "",   NoTypes),
                Msg("wl_output",  "u",  new WaylandInterop.WlInterface*[] { null }),
                Msg("position",   "ii", new WaylandInterop.WlInterface*[] { null, null }),
                Msg("dimensions", "ii", new WaylandInterop.WlInterface*[] { null, null }),
            });

        // River_seat_v1
        Populate(RiverSeat,
            requests: new[]
            {
                Msg("destroy",              "",   NoTypes),
                Msg("focus_window",         "o",  new WaylandInterop.WlInterface*[] { RiverWindow }),
                Msg("focus_shell_surface",  "o",  new WaylandInterop.WlInterface*[] { RiverShellSurface }),
                Msg("clear_focus",          "",   NoTypes),
                Msg("op_start_pointer",     "",   NoTypes),
                Msg("op_end",               "",   NoTypes),
                Msg("get_pointer_binding",  "nuu",new WaylandInterop.WlInterface*[] { RiverPointerBinding, null, null }),
                Msg("set_xcursor_theme",    "2su",new WaylandInterop.WlInterface*[] { null, null }),
                Msg("pointer_warp",         "3ii",new WaylandInterop.WlInterface*[] { null, null }),
            },
            events: new[]
            {
                Msg("removed",                    "",   NoTypes),
                Msg("wl_seat",                    "u",  new WaylandInterop.WlInterface*[] { null }),
                Msg("pointer_enter",              "o",  new WaylandInterop.WlInterface*[] { RiverWindow }),
                Msg("pointer_leave",              "",   NoTypes),
                Msg("window_interaction",         "o",  new WaylandInterop.WlInterface*[] { RiverWindow }),
                Msg("shell_surface_interaction",  "o",  new WaylandInterop.WlInterface*[] { RiverShellSurface }),
                Msg("op_delta",                   "ii", new WaylandInterop.WlInterface*[] { null, null }),
                Msg("op_release",                 "",   NoTypes),
                Msg("pointer_position",           "2ii",new WaylandInterop.WlInterface*[] { null, null }),
            });

        // River_pointer_binding_v1
        Populate(RiverPointerBinding,
            requests: new[]
            {
                Msg("destroy", "", NoTypes),
                Msg("enable",  "", NoTypes),
                Msg("disable", "", NoTypes),
            },
            events: new[]
            {
                Msg("pressed",  "", NoTypes),
                Msg("released", "", NoTypes),
            });

        // River_xkb_bindings_v1
        Populate(RiverXkbBindings,
            requests: new[]
            {
                Msg("destroy", "", NoTypes),
                Msg("get_xkb_binding", "onuu", new WaylandInterop.WlInterface*[] { RiverSeat, RiverXkbBinding, null, null }),
                Msg("get_seat", "2no", new WaylandInterop.WlInterface*[] { RiverXkbBindingsSeat, RiverSeat }),
            },
            events: Array.Empty<WaylandInterop.WlMessage>());

        // River_xkb_binding_v1
        Populate(RiverXkbBinding,
            requests: new[]
            {
                Msg("destroy", "", NoTypes),
                Msg("set_layout_override", "u", new WaylandInterop.WlInterface*[] { null }),
                Msg("enable", "", NoTypes),
                Msg("disable", "", NoTypes),
            },
            events: new[]
            {
                Msg("pressed", "", NoTypes),     // opcode 0
                Msg("released", "", NoTypes),    // opcode 1
                Msg("stop_repeat", "", NoTypes), // opcode 2, since v2 — REQUIRED at bind version 3
            });

        // River_xkb_bindings_seat_v1
        Populate(RiverXkbBindingsSeat,
            requests: new[]
            {
                Msg("destroy", "", NoTypes),
                Msg("set_layout", "u", new WaylandInterop.WlInterface*[] { null }),
            },
            events: Array.Empty<WaylandInterop.WlMessage>());
    }

    /// <summary>
    /// Reserves a forward-declared <see cref="WaylandInterop.WlInterface"/> with no
    /// requests or events, to be filled in later by <see cref="Populate"/>.
    /// </summary>
    /// <param name="name">
    /// Wire-protocol interface name.
    /// </param>
    /// <param name="version">
    /// Interface version.
    /// </param>
    /// <returns>
    /// Pointer to the reserved struct, ready to be filled in by <see cref="Populate"/>.
    /// </returns>
    /// <remarks>
    /// Used so interfaces that reference each other can be allocated up-front before their message
    /// tables are built.
    /// </remarks>
    private static WaylandInterop.WlInterface* AllocEmpty(string name, int version)
    {
        var iface = (WaylandInterop.WlInterface*)Marshal.AllocHGlobal(sizeof(WaylandInterop.WlInterface));
        iface->name = AllocStringUtf8(name);
        iface->version = version;
        iface->method_count = 0;
        iface->methods = IntPtr.Zero;
        iface->event_count = 0;
        iface->events = IntPtr.Zero;
        return iface;
    }

    /// <summary>
    /// Writes <paramref name="requests"/> and <paramref name="events"/> into an
    /// interface previously reserved by <see cref="AllocEmpty"/>.
    /// </summary>
    /// <param name="iface">
    /// Target interface (must be writable unmanaged memory).
    /// </param>
    /// <param name="requests">
    /// Request messages, indexed by opcode.
    /// </param>
    /// <param name="events">
    /// Event messages, indexed by opcode.
    /// </param>
    private static void Populate(WaylandInterop.WlInterface* iface, WaylandInterop.WlMessage[] requests, WaylandInterop.WlMessage[] events)
    {
        iface->method_count = requests.Length;
        iface->methods = AllocMessages(requests);
        iface->event_count = events.Length;
        iface->events = AllocMessages(events);
    }
}
