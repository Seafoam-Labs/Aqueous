using System;
using System.Runtime.InteropServices;
namespace Aqueous.Bindings.AstalWl
{
    public static unsafe partial class AstalWlInterop
    {
        private const string LibName = "libastal-wl.so";
        // AstalWlGlobal
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_wl_global_get_type();
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWlGlobal *")]
        public static partial _AstalWlGlobal* astal_wl_global_dup([NativeTypeName("const AstalWlGlobal *")] _AstalWlGlobal* self);
        [LibraryImport(LibName)]
        public static partial void astal_wl_global_free([NativeTypeName("AstalWlGlobal *")] _AstalWlGlobal* self);
        [LibraryImport(LibName)]
        public static partial void astal_wl_global_copy([NativeTypeName("const AstalWlGlobal *")] _AstalWlGlobal* self, [NativeTypeName("AstalWlGlobal *")] _AstalWlGlobal* dest);
        [LibraryImport(LibName)]
        public static partial void astal_wl_global_destroy([NativeTypeName("AstalWlGlobal *")] _AstalWlGlobal* self);
        // AstalWlRegistry
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_wl_registry_get_type();
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWlRegistry *")]
        public static partial _AstalWlRegistry* astal_wl_get_default();
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWlRegistry *")]
        public static partial _AstalWlRegistry* astal_wl_registry_get_default();
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWlRegistry *")]
        public static partial _AstalWlRegistry* astal_wl_registry_new();
        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_wl_registry_get_globals([NativeTypeName("AstalWlRegistry *")] _AstalWlRegistry* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_wl_registry_get_outputs([NativeTypeName("AstalWlRegistry *")] _AstalWlRegistry* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_wl_registry_get_seats([NativeTypeName("AstalWlRegistry *")] _AstalWlRegistry* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("struct wl_registry *")]
        public static partial _wl_registry* astal_wl_registry_get_registry([NativeTypeName("AstalWlRegistry *")] _AstalWlRegistry* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("struct wl_display *")]
        public static partial _wl_display* astal_wl_registry_get_display([NativeTypeName("AstalWlRegistry *")] _AstalWlRegistry* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_wl_registry_find_globals([NativeTypeName("AstalWlRegistry *")] _AstalWlRegistry* self, [NativeTypeName("const gchar *")] sbyte* @interface);
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWlGlobal *")]
        public static partial _AstalWlGlobal* astal_wl_registry_get_global_by_id([NativeTypeName("AstalWlRegistry *")] _AstalWlRegistry* self, [NativeTypeName("guint32")] uint id);
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWlOutput *")]
        public static partial _AstalWlOutput* astal_wl_registry_get_output_by_id([NativeTypeName("AstalWlRegistry *")] _AstalWlRegistry* self, [NativeTypeName("guint32")] uint id);
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWlOutput *")]
        public static partial _AstalWlOutput* astal_wl_registry_get_output_by_name([NativeTypeName("AstalWlRegistry *")] _AstalWlRegistry* self, [NativeTypeName("const gchar *")] sbyte* name);
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWlOutput *")]
        public static partial _AstalWlOutput* astal_wl_registry_get_output_by_wl_output([NativeTypeName("AstalWlRegistry *")] _AstalWlRegistry* self, [NativeTypeName("struct wl_output *")] _wl_output* wl_output);
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWlSeat *")]
        public static partial _AstalWlSeat* astal_wl_registry_get_seat_by_id([NativeTypeName("AstalWlRegistry *")] _AstalWlRegistry* self, [NativeTypeName("guint32")] uint id);
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWlSeat *")]
        public static partial _AstalWlSeat* astal_wl_registry_get_seat_by_name([NativeTypeName("AstalWlRegistry *")] _AstalWlRegistry* self, [NativeTypeName("const gchar *")] sbyte* name);
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWlSeat *")]
        public static partial _AstalWlSeat* astal_wl_registry_get_seat_by_wl_seat([NativeTypeName("AstalWlRegistry *")] _AstalWlRegistry* self, [NativeTypeName("struct wl_seat *")] _wl_seat* wl_seat);
        // AstalWlOutput enums
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_wl_output_subpixel_get_type();
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_wl_output_transform_get_type();
        // AstalWlOutput
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_wl_output_get_type();
        [LibraryImport(LibName)]
        [return: NativeTypeName("struct wl_output *")]
        public static partial _wl_output* astal_wl_output_get_wl_output([NativeTypeName("AstalWlOutput *")] _AstalWlOutput* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("guint32")]
        public static partial uint astal_wl_output_get_id([NativeTypeName("AstalWlOutput *")] _AstalWlOutput* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWlRectangle *")]
        public static partial _AstalWlRectangle* astal_wl_output_get_geometry([NativeTypeName("AstalWlOutput *")] _AstalWlOutput* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gint")]
        public static partial int astal_wl_output_get_physical_width([NativeTypeName("AstalWlOutput *")] _AstalWlOutput* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gint")]
        public static partial int astal_wl_output_get_physical_height([NativeTypeName("AstalWlOutput *")] _AstalWlOutput* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_wl_output_get_refresh_rate([NativeTypeName("AstalWlOutput *")] _AstalWlOutput* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWlOutputTransform")]
        public static partial int astal_wl_output_get_transform([NativeTypeName("AstalWlOutput *")] _AstalWlOutput* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWlOutputSubpixel")]
        public static partial int astal_wl_output_get_subpixel([NativeTypeName("AstalWlOutput *")] _AstalWlOutput* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_wl_output_get_make([NativeTypeName("AstalWlOutput *")] _AstalWlOutput* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_wl_output_get_model([NativeTypeName("AstalWlOutput *")] _AstalWlOutput* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_wl_output_get_scale([NativeTypeName("AstalWlOutput *")] _AstalWlOutput* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_wl_output_get_name([NativeTypeName("AstalWlOutput *")] _AstalWlOutput* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_wl_output_get_description([NativeTypeName("AstalWlOutput *")] _AstalWlOutput* self);
        // AstalWlSeat enums
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_wl_seat_capabilities_get_type();
        // AstalWlSeat
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_wl_seat_get_type();
        [LibraryImport(LibName)]
        [return: NativeTypeName("struct wl_seat *")]
        public static partial _wl_seat* astal_wl_seat_get_wl_seat([NativeTypeName("AstalWlSeat *")] _AstalWlSeat* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("guint32")]
        public static partial uint astal_wl_seat_get_id([NativeTypeName("AstalWlSeat *")] _AstalWlSeat* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_wl_seat_get_name([NativeTypeName("AstalWlSeat *")] _AstalWlSeat* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWlSeatCapabilities")]
        public static partial int astal_wl_seat_get_capabilities([NativeTypeName("AstalWlSeat *")] _AstalWlSeat* self);
        // AstalWlRectangle
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_wl_rectangle_get_type();
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalWlRectangle *")]
        public static partial _AstalWlRectangle* astal_wl_rectangle_dup([NativeTypeName("const AstalWlRectangle *")] _AstalWlRectangle* self);
        [LibraryImport(LibName)]
        public static partial void astal_wl_rectangle_free([NativeTypeName("AstalWlRectangle *")] _AstalWlRectangle* self);
        [LibraryImport(LibName)]
        public static partial void astal_wl_rectangle_init_zero([NativeTypeName("AstalWlRectangle *")] _AstalWlRectangle* self);
        [LibraryImport(LibName)]
        public static partial void astal_wl_rectangle_copy([NativeTypeName("AstalWlRectangle *")] _AstalWlRectangle* self, [NativeTypeName("AstalWlRectangle *")] _AstalWlRectangle* result);
        [LibraryImport(LibName)]
        public static partial void astal_wl_rectangle_normalize([NativeTypeName("AstalWlRectangle *")] _AstalWlRectangle* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_wl_rectangle_intersect([NativeTypeName("AstalWlRectangle *")] _AstalWlRectangle* a, [NativeTypeName("AstalWlRectangle *")] _AstalWlRectangle* b, [NativeTypeName("AstalWlRectangle *")] _AstalWlRectangle* result);
    }
}
