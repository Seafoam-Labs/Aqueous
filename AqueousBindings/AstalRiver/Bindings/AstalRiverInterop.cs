using System;
using System.Runtime.InteropServices;
namespace Aqueous.Bindings.AstalRiver
{
    public static unsafe partial class AstalRiverInterop
    {
        private const string LibName = "libastal-river.so";

        // AstalRiverRiver
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_river_river_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalRiverRiver *")]
        public static partial _AstalRiverRiver* astal_river_river_new();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalRiverRiver *")]
        public static partial _AstalRiverRiver* astal_river_river_get_default();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalRiverRiver *")]
        public static partial _AstalRiverRiver* astal_river_get_default();

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_river_river_get_outputs([NativeTypeName("AstalRiverRiver *")] _AstalRiverRiver* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalRiverOutput *")]
        public static partial _AstalRiverOutput* astal_river_river_get_focused_output([NativeTypeName("AstalRiverRiver *")] _AstalRiverRiver* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_river_river_get_focused_view([NativeTypeName("AstalRiverRiver *")] _AstalRiverRiver* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_river_river_get_mode([NativeTypeName("AstalRiverRiver *")] _AstalRiverRiver* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalRiverOutput *")]
        public static partial _AstalRiverOutput* astal_river_river_get_output([NativeTypeName("AstalRiverRiver *")] _AstalRiverRiver* self, [NativeTypeName("const gchar *")] sbyte* name);

        // AstalRiverOutput
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_river_output_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("guint")]
        public static partial uint astal_river_output_get_id([NativeTypeName("AstalRiverOutput *")] _AstalRiverOutput* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_river_output_get_name([NativeTypeName("AstalRiverOutput *")] _AstalRiverOutput* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("guint")]
        public static partial uint astal_river_output_get_focused_tags([NativeTypeName("AstalRiverOutput *")] _AstalRiverOutput* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("guint")]
        public static partial uint astal_river_output_get_occupied_tags([NativeTypeName("AstalRiverOutput *")] _AstalRiverOutput* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("guint")]
        public static partial uint astal_river_output_get_urgent_tags([NativeTypeName("AstalRiverOutput *")] _AstalRiverOutput* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_river_output_get_layout([NativeTypeName("AstalRiverOutput *")] _AstalRiverOutput* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_river_output_get_focused([NativeTypeName("AstalRiverOutput *")] _AstalRiverOutput* self);

        // --- GObject signal subscription shims (Phase 3) ---
        // `g_signal_connect_data` is the canonical low-level signal attach; the
        // usual `g_signal_connect` is a macro expanding to this call with flags=0.
        // We use LPUTF8Str marshaling for the signal name so "notify::<prop>" flows
        // through without extra allocation.
        [DllImport("libgobject-2.0.so.0", EntryPoint = "g_signal_connect_data", CharSet = CharSet.Ansi)]
        public static extern ulong g_signal_connect_data(
            IntPtr instance,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string detailedSignal,
            IntPtr cHandler,
            IntPtr data,
            IntPtr destroyData,
            int connectFlags);

        [DllImport("libgobject-2.0.so.0", EntryPoint = "g_signal_handler_disconnect")]
        public static extern void g_signal_handler_disconnect(IntPtr instance, ulong handlerId);

        [DllImport("libgobject-2.0.so.0", EntryPoint = "g_object_ref")]
        public static extern IntPtr g_object_ref(IntPtr obj);

        [DllImport("libgobject-2.0.so.0", EntryPoint = "g_object_unref")]
        public static extern void g_object_unref(IntPtr obj);
    }
}
