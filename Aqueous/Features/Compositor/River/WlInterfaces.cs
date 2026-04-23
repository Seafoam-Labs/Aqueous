using System;
using System.Runtime.InteropServices;
using System.Text;

namespace Aqueous.Features.Compositor.River
{
    /// <summary>
    /// Builds the unmanaged <c>wl_interface</c> + <c>wl_message</c> tables used
    /// by <see cref="ForeignToplevelClient"/>.
    ///
    /// <para>
    /// libwayland-client is strict: every proxy must be tagged with a real
    /// <c>wl_interface*</c> whose <c>methods</c> / <c>events</c> arrays exactly
    /// describe the wire protocol (message name, signature string, and the
    /// nested interface pointers for <c>object</c> / <c>new_id</c> typed args).
    /// We build only the four interfaces we actually touch:
    /// </para>
    /// <list type="bullet">
    /// <item><c>wl_registry</c> — just enough to issue <c>bind</c> and read
    /// <c>global</c> / <c>global_remove</c>.</item>
    /// <item><c>wl_seat</c> — only the interface identity; we never issue
    /// requests on it, we just hand its proxy pointer to
    /// <c>zwlr_foreign_toplevel_handle_v1.activate</c>.</item>
    /// <item><c>zwlr_foreign_toplevel_manager_v1</c> v3.</item>
    /// <item><c>zwlr_foreign_toplevel_handle_v1</c> v3.</item>
    /// </list>
    ///
    /// <para>
    /// Every string / struct is allocated with <see cref="Marshal.AllocHGlobal(int)"/>
    /// and intentionally never freed — these tables live for the process
    /// lifetime (matching what wayland-scanner-generated C code does: they're
    /// static globals).
    /// </para>
    /// </summary>
    internal static unsafe class WlInterfaces
    {
        public static WaylandInterop.WlInterface* WlRegistry;
        public static WaylandInterop.WlInterface* WlSeat;
        public static WaylandInterop.WlInterface* WlSurface;      // used as null placeholder for rectangle()
        public static WaylandInterop.WlInterface* WlOutput;       // used as null placeholder for output_enter/leave
        public static WaylandInterop.WlInterface* ZwlrManager;
        public static WaylandInterop.WlInterface* ZwlrHandle;

        private static bool _built;
        private static readonly object _lock = new();

        public static void EnsureBuilt()
        {
            if (_built) return;
            lock (_lock)
            {
                if (_built) return;
                BuildAll();
                _built = true;
            }
        }

        // ---------- builders ----------

        // C# can't use pointer types as generic type args, so we keep a
        // pre-made empty array handy for messages with no typed args.
        private static readonly WaylandInterop.WlInterface*[] NoTypes = new WaylandInterop.WlInterface*[0];

        private static IntPtr AllocStringUtf8(string s)
        {
            var bytes = Encoding.UTF8.GetBytes(s);
            var p = Marshal.AllocHGlobal(bytes.Length + 1);
            Marshal.Copy(bytes, 0, p, bytes.Length);
            Marshal.WriteByte(p, bytes.Length, 0);
            return p;
        }

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

        private static IntPtr AllocMessages(WaylandInterop.WlMessage[] messages)
        {
            if (messages.Length == 0) return IntPtr.Zero;
            var p = (WaylandInterop.WlMessage*)Marshal.AllocHGlobal(sizeof(WaylandInterop.WlMessage) * messages.Length);
            for (int i = 0; i < messages.Length; i++) p[i] = messages[i];
            return (IntPtr)p;
        }

        private static WaylandInterop.WlMessage Msg(string name, string signature, WaylandInterop.WlInterface*[] types)
        {
            return new WaylandInterop.WlMessage
            {
                name = AllocStringUtf8(name),
                signature = AllocStringUtf8(signature),
                types = AllocTypes(types),
            };
        }

        private static IntPtr AllocTypes(WaylandInterop.WlInterface*[] types)
        {
            if (types.Length == 0) return IntPtr.Zero;
            var p = (IntPtr*)Marshal.AllocHGlobal(IntPtr.Size * types.Length);
            for (int i = 0; i < types.Length; i++) p[i] = (IntPtr)types[i];
            return (IntPtr)p;
        }

        // ---------- build graph ----------
        //
        // Interfaces reference each other (e.g. manager's "toplevel" event
        // yields a new_id<handle>) so we allocate the structs first and then
        // populate their message tables. This mirrors how wayland-scanner
        // emits C code with forward declarations.

        private static void BuildAll()
        {
            // 1. Allocate empty interface structs so later messages can point at them.
            WlRegistry   = AllocEmpty("wl_registry", 1);
            WlSeat       = AllocEmpty("wl_seat", 7);
            WlSurface    = AllocEmpty("wl_surface", 1);
            WlOutput     = AllocEmpty("wl_output", 1);
            ZwlrManager  = AllocEmpty("zwlr_foreign_toplevel_manager_v1", 3);
            ZwlrHandle   = AllocEmpty("zwlr_foreign_toplevel_handle_v1", 3);

            // 2. wl_registry
            //    request 0: bind(name: uint, id: new_id<?>)  — untyped new_id = "sun" prefix
            //    event   0: global(name: uint, interface: string, version: uint)
            //    event   1: global_remove(name: uint)
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

            // 3. wl_seat — we never send requests; skip methods. Events list
            //    can be empty since we never attach a dispatcher to the seat.
            Populate(WlSeat, requests: Array.Empty<WaylandInterop.WlMessage>(), events: Array.Empty<WaylandInterop.WlMessage>());

            // 4. wl_surface / wl_output — only the name matters; messages
            //    are unused (we never create these ourselves and never
            //    interpret their events).
            Populate(WlSurface, Array.Empty<WaylandInterop.WlMessage>(), Array.Empty<WaylandInterop.WlMessage>());
            Populate(WlOutput,  Array.Empty<WaylandInterop.WlMessage>(), Array.Empty<WaylandInterop.WlMessage>());

            // 5. zwlr_foreign_toplevel_manager_v1 (version 3)
            //    request 0: stop()
            //    event   0: toplevel(new_id<handle>)
            //    event   1: finished()
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

            // 6. zwlr_foreign_toplevel_handle_v1 (version 3)
            //
            //    requests (as per wayland-protocols XML):
            //     0 set_maximized()
            //     1 unset_maximized()
            //     2 set_minimized()
            //     3 unset_minimized()
            //     4 activate(wl_seat)
            //     5 close()
            //     6 set_rectangle(wl_surface, int, int, int, int)
            //     7 destroy()                         [destructor]
            //     8 set_fullscreen(?wl_output)        [since v2]
            //     9 unset_fullscreen()                [since v2]
            //
            //    events:
            //     0 title(string)
            //     1 app_id(string)
            //     2 output_enter(object<wl_output>)
            //     3 output_leave(object<wl_output>)
            //     4 state(array)
            //     5 done()
            //     6 closed()
            //     7 parent(?object<handle>)           [since v3]
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
        }

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

        private static void Populate(WaylandInterop.WlInterface* iface, WaylandInterop.WlMessage[] requests, WaylandInterop.WlMessage[] events)
        {
            iface->method_count = requests.Length;
            iface->methods = AllocMessages(requests);
            iface->event_count = events.Length;
            iface->events = AllocMessages(events);
        }
    }
}
