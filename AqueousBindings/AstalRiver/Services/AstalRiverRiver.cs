using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalRiver;
namespace Aqueous.Bindings.AstalRiver.Services
{
    /// <summary>
    /// Wraps the top-level AstalRiver "River" GObject, providing access to outputs,
    /// the currently focused output/view, and the active River mode.
    /// </summary>
    public unsafe class AstalRiverRiver
    {
        private readonly _AstalRiverRiver* _handle;
        internal _AstalRiverRiver* Handle => _handle;

        internal AstalRiverRiver(_AstalRiverRiver* handle)
        {
            _handle = handle;
        }

        /// <summary>Returns the default singleton River instance, or null if unavailable.</summary>
        public static AstalRiverRiver? GetDefault()
        {
            var ptr = AstalRiverInterop.astal_river_river_get_default();
            return ptr == null ? null : new AstalRiverRiver(ptr);
        }

        /// <summary>All outputs known to the River compositor.</summary>
        public IEnumerable<AstalRiverOutput> Outputs
        {
            get
            {
                var listPtr = AstalRiverInterop.astal_river_river_get_outputs(_handle);
                return WrapGList<AstalRiverOutput>(listPtr, p => new AstalRiverOutput((_AstalRiverOutput*)(void*)p));
            }
        }

        /// <summary>Currently focused output, or null if none is focused.</summary>
        public AstalRiverOutput? FocusedOutput
        {
            get
            {
                var ptr = AstalRiverInterop.astal_river_river_get_focused_output(_handle);
                return ptr == null ? null : new AstalRiverOutput(ptr);
            }
        }

        /// <summary>App-id / title of the currently focused view, or null.</summary>
        public string? FocusedView =>
            Marshal.PtrToStringUTF8((IntPtr)AstalRiverInterop.astal_river_river_get_focused_view(_handle));

        /// <summary>Active River keybinding mode (e.g. "normal").</summary>
        public string? Mode =>
            Marshal.PtrToStringUTF8((IntPtr)AstalRiverInterop.astal_river_river_get_mode(_handle));

        /// <summary>Native handle as <see cref="IntPtr"/>, for GObject signal plumbing.</summary>
        public IntPtr NativePtr => (IntPtr)_handle;

        /// <summary>
        /// Connect a GObject <c>notify::&lt;property&gt;</c> signal.
        /// Returns the handler id (use <see cref="Disconnect"/> to remove).
        /// </summary>
        public ulong ConnectNotify(string property, IntPtr callback, IntPtr userData)
            => AstalRiverInterop.g_signal_connect_data(
                   (IntPtr)_handle,
                   "notify::" + property,
                   callback,
                   userData,
                   IntPtr.Zero,
                   0);

        /// <summary>Disconnect a previously-connected signal handler.</summary>
        public void Disconnect(ulong handlerId)
            => AstalRiverInterop.g_signal_handler_disconnect((IntPtr)_handle, handlerId);

        /// <summary>Look up an output by name (e.g. "DP-1").</summary>
        public AstalRiverOutput? GetOutput(string name)
        {
            fixed (byte* ptr = System.Text.Encoding.UTF8.GetBytes(name + '\0'))
            {
                var result = AstalRiverInterop.astal_river_river_get_output(_handle, (sbyte*)ptr);
                return result == null ? null : new AstalRiverOutput(result);
            }
        }

        private static IEnumerable<T> WrapGList<T>(_GList* listPtr, Func<IntPtr, T> wrap)
        {
            var results = new List<T>();
            var current = listPtr;
            while (current != null)
            {
                void* data = *(void**)current;
                results.Add(wrap((IntPtr)data));
                current = *(_GList**)((byte*)current + sizeof(void*));
            }
            return results;
        }
    }
}
