using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Aqueous.Features.Compositor.River
{
    /// <summary>
    /// Hand-rolled <c>wlr-foreign-toplevel-management-unstable-v1</c> client.
    ///
    /// <para>
    /// Phase 4b scaffold — this first iteration focuses on getting the hard
    /// parts right:
    /// </para>
    /// <list type="bullet">
    /// <item>A separate <c>wl_display_connect()</c> from GDK's, on its own
    /// worker thread.</item>
    /// <item>Hand-built <see cref="WaylandInterop.WlInterface"/> / <c>wl_message</c>
    /// tables for <c>wl_registry</c>, <c>wl_seat</c>,
    /// <c>zwlr_foreign_toplevel_manager_v1</c>, and
    /// <c>zwlr_foreign_toplevel_handle_v1</c>.</item>
    /// <item>A single <see cref="UnmanagedCallersOnlyAttribute"/> dispatcher
    /// that demuxes events by proxy + opcode.</item>
    /// <item>Read-only snapshot of toplevels (<see cref="Toplevels"/>); view-
    /// targeted writes (activate / close / set_minimized) are wired in a
    /// follow-up iteration once the read path is proven under a live River
    /// session.</item>
    /// </list>
    ///
    /// <para>
    /// The client is gated behind the <c>AQUEOUS_FOREIGN_TOPLEVEL</c>
    /// environment variable so the existing <see cref="RiverBackend"/> behaviour
    /// is preserved by default.
    /// </para>
    /// </summary>
    internal sealed unsafe class ForeignToplevelClient : IDisposable
    {
        // ---------- Public snapshot API ----------

        public readonly record struct ToplevelInfo(
            int Id,
            string? Title,
            string? AppId,
            bool Activated,
            bool Maximized,
            bool Minimized,
            bool Fullscreen);

        /// <summary>Fires on the worker thread after any toplevel <c>done</c> event.</summary>
        public event Action? Changed;

        public IReadOnlyList<ToplevelInfo> Toplevels
        {
            get
            {
                lock (_lock)
                {
                    var snap = new ToplevelInfo[_toplevels.Count];
                    int i = 0;
                    foreach (var t in _toplevels.Values)
                        snap[i++] = t.Snapshot();
                    return snap;
                }
            }
        }

        public bool IsConnected => _display != IntPtr.Zero && _manager != IntPtr.Zero;

        // ---------- State ----------

        private IntPtr _display;
        private IntPtr _registry;
        private IntPtr _manager;      // zwlr_foreign_toplevel_manager_v1
        private IntPtr _seat;         // first wl_seat; used later for activate()
        private uint   _seatVersion;
        private Thread? _pumpThread;
        private volatile bool _running;
        private readonly object _lock = new();
        private int _nextId = 1;

        private readonly ConcurrentDictionary<IntPtr, ToplevelEntry> _toplevels = new();

        private sealed class ToplevelEntry
        {
            public int Id;
            public string? Title;
            public string? AppId;
            public bool Activated;
            public bool Maximized;
            public bool Minimized;
            public bool Fullscreen;

            // Pending fields — wlr spec says handle events are batched and only
            // applied on done(). We accumulate into "pending_*" and flip on done.
            public string? PendingTitle;
            public string? PendingAppId;
            public bool PendingActivated;
            public bool PendingMaximized;
            public bool PendingMinimized;
            public bool PendingFullscreen;
            public bool HasPendingState;

            public ToplevelInfo Snapshot() =>
                new(Id, Title, AppId, Activated, Maximized, Minimized, Fullscreen);
        }

        // ---------- Lifecycle ----------

        /// <summary>
        /// Singleton-style factory. Returns <c>null</c> if libwayland isn't
        /// available, connection fails, or the manager global isn't advertised.
        /// </summary>
        public static ForeignToplevelClient? TryStart()
        {
            try
            {
                var c = new ForeignToplevelClient();
                if (!c.Connect()) { c.Dispose(); return null; }
                c.StartPump();
                return c;
            }
            catch (DllNotFoundException) { return null; }
            catch { return null; }
        }

        private bool Connect()
        {
            _display = WaylandInterop.wl_display_connect(IntPtr.Zero);
            if (_display == IntPtr.Zero) return false;

            WlInterfaces.EnsureBuilt();

            // Get the registry. wl_display.get_registry is opcode 1.
            // It takes one new_id arg. We use wl_proxy_marshal_flags with
            // the interface of wl_registry and version 1.
            _registry = WaylandInterop.wl_proxy_marshal_flags(
                _display,
                1, // wl_display::get_registry opcode
                (IntPtr)WlInterfaces.WlRegistry,
                1,
                0,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            if (_registry == IntPtr.Zero) return false;

            var self = GCHandle.Alloc(this, GCHandleType.Normal);
            _selfHandle = self;
            WaylandInterop.wl_proxy_add_dispatcher(_registry, (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Dispatch, IntPtr.Zero, GCHandle.ToIntPtr(self));

            // Roundtrip so globals flush.
            WaylandInterop.wl_display_roundtrip(_display);
            // Second roundtrip so the manager binding and any initial toplevel
            // events are delivered before we return.
            WaylandInterop.wl_display_roundtrip(_display);

            return _manager != IntPtr.Zero;
        }

        private GCHandle _selfHandle;

        private void StartPump()
        {
            _running = true;
            _pumpThread = new Thread(PumpLoop)
            {
                IsBackground = true,
                Name = "Aqueous.ForeignToplevelClient",
            };
            _pumpThread.Start();
        }

        private void PumpLoop()
        {
            try
            {
                while (_running)
                {
                    int r = WaylandInterop.wl_display_dispatch(_display);
                    if (r < 0) break;
                }
            }
            catch { /* swallow — the worker must not crash the app */ }
        }

        public void Dispose()
        {
            _running = false;
            try
            {
                if (_manager != IntPtr.Zero)
                {
                    // zwlr_foreign_toplevel_manager_v1::stop (opcode 0) — destructor.
                    WaylandInterop.wl_proxy_marshal_flags(
                        _manager, 0, IntPtr.Zero, 0, WaylandInterop.WL_MARSHAL_FLAG_DESTROY,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                    _manager = IntPtr.Zero;
                }

                if (_display != IntPtr.Zero)
                {
                    WaylandInterop.wl_display_disconnect(_display);
                    _display = IntPtr.Zero;
                }

                _pumpThread?.Join(500);
            }
            catch { }
            finally
            {
                if (_selfHandle.IsAllocated) _selfHandle.Free();
            }
        }

        // ---------- Dispatcher ----------
        //
        // wl_dispatcher_func_t signature (from libwayland):
        //   int (*)(const void *implementation, void *target, uint32_t opcode,
        //           const struct wl_message *msg, union wl_argument *args);
        //
        // The trampoline reads args out of the wl_argument union based on the
        // signature of the wl_message. For our purposes we only dispatch a
        // small set of (proxy, opcode) pairs and handle each inline.

        [UnmanagedCallersOnly]
        private static int Dispatch(IntPtr implementation, IntPtr target, uint opcode, IntPtr msg, IntPtr args)
        {
            try
            {
                var gch = GCHandle.FromIntPtr(implementation);
                var self = gch.Target as ForeignToplevelClient;
                if (self == null) return 0;

                // Which proxy is `target`? Match against the three we care about.
                if (target == self._registry)
                    self.OnRegistryEvent(opcode, (WlArgument*)args);
                else if (target == self._manager)
                    self.OnManagerEvent(opcode, (WlArgument*)args);
                else
                    self.OnHandleEvent(target, opcode, (WlArgument*)args);
            }
            catch { /* swallow — never unwind into native dispatch */ }
            return 0;
        }

        /// <summary>libwayland's <c>union wl_argument</c> — one pointer-sized slot.</summary>
        [StructLayout(LayoutKind.Explicit)]
        private struct WlArgument
        {
            [FieldOffset(0)] public int   i;
            [FieldOffset(0)] public uint  u;
            [FieldOffset(0)] public int   fx;   // fixed
            [FieldOffset(0)] public IntPtr s;   // const char*
            [FieldOffset(0)] public IntPtr o;   // struct wl_object*
            [FieldOffset(0)] public uint  n;    // new_id
            [FieldOffset(0)] public IntPtr a;   // struct wl_array*
            [FieldOffset(0)] public int   h;    // fd
        }

        // ---------- wl_registry events ----------

        private void OnRegistryEvent(uint opcode, WlArgument* args)
        {
            // wl_registry events:
            //   0  global(name: uint, interface: string, version: uint)
            //   1  global_remove(name: uint)
            if (opcode != 0) return;

            uint   name      = args[0].u;
            string? iface    = PtrToString(args[1].s);
            uint   version   = args[2].u;
            if (iface == null) return;

            if (iface == "zwlr_foreign_toplevel_manager_v1" && _manager == IntPtr.Zero)
            {
                uint bindVersion = Math.Min(version, 3u);
                _manager = Bind(name, WlInterfaces.ZwlrManager, bindVersion);
                if (_manager != IntPtr.Zero)
                {
                    WaylandInterop.wl_proxy_add_dispatcher(
                        _manager,
                        (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Dispatch,
                        IntPtr.Zero,
                        GCHandle.ToIntPtr(_selfHandle));
                }
            }
            else if (iface == "wl_seat" && _seat == IntPtr.Zero)
            {
                _seatVersion = Math.Min(version, 7u);
                _seat = Bind(name, WlInterfaces.WlSeat, _seatVersion);
                // No dispatcher needed — we never read seat events, only use
                // its proxy as a target for zwlr_foreign_toplevel_handle.activate.
            }
        }

        private IntPtr Bind(uint name, WaylandInterop.WlInterface* iface, uint version)
        {
            // wl_registry::bind(name: uint, id: new_id) — new_id has no
            // interface arg in the XML, so the signature on the wire is
            // "usun": name, interface name string, interface version, new_id.
            // libwayland's wl_proxy_marshal_flags takes those as separate args.
            var nameBytes = Encoding.UTF8.GetBytes(((IntPtr)iface->name) == IntPtr.Zero
                ? "" : Marshal.PtrToStringUTF8(iface->name) ?? "");
            fixed (byte* _ = nameBytes)
            {
                // Note: we pass the interface via the dedicated `iface` param
                // of wl_proxy_marshal_flags — libwayland handles the wire
                // format and we only need to supply (name, version).
                return WaylandInterop.wl_proxy_marshal_flags(
                    _registry,
                    0, // wl_registry::bind opcode
                    (IntPtr)iface,
                    version,
                    0,
                    (IntPtr)name,
                    (IntPtr)iface->name,
                    (IntPtr)version,
                    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            }
        }

        // ---------- manager events ----------

        private void OnManagerEvent(uint opcode, WlArgument* args)
        {
            // 0 toplevel(new_id<handle>)
            // 1 finished()
            if (opcode != 0) return;

            IntPtr handleProxy = args[0].o;
            if (handleProxy == IntPtr.Zero) return;

            var entry = new ToplevelEntry { Id = Interlocked.Increment(ref _nextId) };
            _toplevels[handleProxy] = entry;

            WaylandInterop.wl_proxy_add_dispatcher(
                handleProxy,
                (IntPtr)(delegate* unmanaged<IntPtr, IntPtr, uint, IntPtr, IntPtr, int>)&Dispatch,
                IntPtr.Zero,
                GCHandle.ToIntPtr(_selfHandle));
        }

        // ---------- zwlr_foreign_toplevel_handle_v1 events ----------

        private void OnHandleEvent(IntPtr handle, uint opcode, WlArgument* args)
        {
            if (!_toplevels.TryGetValue(handle, out var entry)) return;

            // Events (v3):
            //  0 title(string)
            //  1 app_id(string)
            //  2 output_enter(object)
            //  3 output_leave(object)
            //  4 state(array<uint>)
            //  5 done()
            //  6 closed()
            //  7 parent(object?<handle>)       v3
            switch (opcode)
            {
                case 0:
                    entry.PendingTitle = PtrToString(args[0].s);
                    entry.HasPendingState = true;
                    break;
                case 1:
                    entry.PendingAppId = PtrToString(args[0].s);
                    entry.HasPendingState = true;
                    break;
                case 4:
                    DecodeStateArray(args[0].a, out var act, out var max, out var min, out var full);
                    entry.PendingActivated = act;
                    entry.PendingMaximized = max;
                    entry.PendingMinimized = min;
                    entry.PendingFullscreen = full;
                    entry.HasPendingState = true;
                    break;
                case 5: // done — commit pending
                    lock (_lock)
                    {
                        if (entry.HasPendingState)
                        {
                            if (entry.PendingTitle != null) entry.Title = entry.PendingTitle;
                            if (entry.PendingAppId != null) entry.AppId = entry.PendingAppId;
                            entry.Activated = entry.PendingActivated;
                            entry.Maximized = entry.PendingMaximized;
                            entry.Minimized = entry.PendingMinimized;
                            entry.Fullscreen = entry.PendingFullscreen;
                            entry.HasPendingState = false;
                        }
                    }
                    try { Changed?.Invoke(); } catch { }
                    break;
                case 6: // closed
                    _toplevels.TryRemove(handle, out _);
                    // destructor
                    WaylandInterop.wl_proxy_marshal_flags(
                        handle, 5 /* destroy */, IntPtr.Zero, 0, WaylandInterop.WL_MARSHAL_FLAG_DESTROY,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                    try { Changed?.Invoke(); } catch { }
                    break;
            }
        }

        private static void DecodeStateArray(IntPtr wlArrayPtr, out bool activated, out bool maximized, out bool minimized, out bool fullscreen)
        {
            activated = maximized = minimized = fullscreen = false;
            if (wlArrayPtr == IntPtr.Zero) return;

            // struct wl_array { size_t size; size_t alloc; void* data; }
            var size = (nuint)Marshal.ReadIntPtr(wlArrayPtr, 0);
            var data = Marshal.ReadIntPtr(wlArrayPtr, IntPtr.Size * 2);
            if (data == IntPtr.Zero) return;

            uint count = (uint)(size / sizeof(uint));
            uint* p = (uint*)data;
            for (uint i = 0; i < count; i++)
            {
                // wlr states: 0=maximized 1=minimized 2=activated 3=fullscreen
                switch (p[i])
                {
                    case 0: maximized = true; break;
                    case 1: minimized = true; break;
                    case 2: activated = true; break;
                    case 3: fullscreen = true; break;
                }
            }
        }

        private static string? PtrToString(IntPtr p) =>
            p == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(p);
    }
}
