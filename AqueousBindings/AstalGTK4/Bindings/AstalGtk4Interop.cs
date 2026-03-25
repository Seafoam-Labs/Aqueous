using System;
using System.Runtime.InteropServices;

namespace Aqueous.Bindings.AstalGTK4
{
    public static unsafe partial class AstalGtk4Interop
    {
        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_bin_get_type();

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("AstalBin *")]
        public static partial _AstalBin* astal_bin_new();

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("AstalBin *")]
        public static partial _AstalBin* astal_bin_construct([NativeTypeName("GType")] nuint object_type);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("GtkWidget *")]
        public static partial _GtkWidget* astal_bin_get_child([NativeTypeName("AstalBin *")] _AstalBin* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_bin_set_child([NativeTypeName("AstalBin *")] _AstalBin* self, [NativeTypeName("GtkWidget *")] _GtkWidget* value);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_box_get_type();

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("AstalBox *")]
        public static partial _AstalBox* astal_box_new();

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("AstalBox *")]
        public static partial _AstalBox* astal_box_construct([NativeTypeName("GType")] nuint object_type);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_box_get_vertical([NativeTypeName("AstalBox *")] _AstalBox* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_box_set_vertical([NativeTypeName("AstalBox *")] _AstalBox* self, [NativeTypeName("gboolean")] int value);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_box_get_children([NativeTypeName("AstalBox *")] _AstalBox* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_box_set_children([NativeTypeName("AstalBox *")] _AstalBox* self, [NativeTypeName("GList *")] _GList* value);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("GtkWidget *")]
        public static partial _GtkWidget* astal_box_get_child([NativeTypeName("AstalBox *")] _AstalBox* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_box_set_child([NativeTypeName("AstalBox *")] _AstalBox* self, [NativeTypeName("GtkWidget *")] _GtkWidget* value);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_slider_get_type();

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("AstalSlider *")]
        public static partial _AstalSlider* astal_slider_new();

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("AstalSlider *")]
        public static partial _AstalSlider* astal_slider_construct([NativeTypeName("GType")] nuint object_type);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_slider_get_value([NativeTypeName("AstalSlider *")] _AstalSlider* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_slider_set_value([NativeTypeName("AstalSlider *")] _AstalSlider* self, [NativeTypeName("gdouble")] double value);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_slider_get_min([NativeTypeName("AstalSlider *")] _AstalSlider* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_slider_set_min([NativeTypeName("AstalSlider *")] _AstalSlider* self, [NativeTypeName("gdouble")] double value);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_slider_get_max([NativeTypeName("AstalSlider *")] _AstalSlider* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_slider_set_max([NativeTypeName("AstalSlider *")] _AstalSlider* self, [NativeTypeName("gdouble")] double value);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_slider_get_step([NativeTypeName("AstalSlider *")] _AstalSlider* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_slider_set_step([NativeTypeName("AstalSlider *")] _AstalSlider* self, [NativeTypeName("gdouble")] double value);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_slider_get_page([NativeTypeName("AstalSlider *")] _AstalSlider* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_slider_set_page([NativeTypeName("AstalSlider *")] _AstalSlider* self, [NativeTypeName("gdouble")] double value);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_window_anchor_get_type();

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_exclusivity_get_type();

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_layer_get_type();

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_keymode_get_type();

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_window_get_type();

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("GdkMonitor *")]
        public static partial _GdkMonitor* astal_window_get_current_monitor([NativeTypeName("AstalWindow *")] _AstalWindow* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("AstalWindow *")]
        public static partial _AstalWindow* astal_window_new();

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("AstalWindow *")]
        public static partial _AstalWindow* astal_window_construct([NativeTypeName("GType")] nuint object_type);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_window_get_namespace([NativeTypeName("AstalWindow *")] _AstalWindow* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_window_set_namespace([NativeTypeName("AstalWindow *")] _AstalWindow* self, [NativeTypeName("const gchar *")] sbyte* value);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial AstalWindowAnchor astal_window_get_anchor([NativeTypeName("AstalWindow *")] _AstalWindow* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_window_set_anchor([NativeTypeName("AstalWindow *")] _AstalWindow* self, AstalWindowAnchor value);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial AstalExclusivity astal_window_get_exclusivity([NativeTypeName("AstalWindow *")] _AstalWindow* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_window_set_exclusivity([NativeTypeName("AstalWindow *")] _AstalWindow* self, AstalExclusivity value);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial AstalLayer astal_window_get_layer([NativeTypeName("AstalWindow *")] _AstalWindow* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_window_set_layer([NativeTypeName("AstalWindow *")] _AstalWindow* self, AstalLayer value);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial AstalKeymode astal_window_get_keymode([NativeTypeName("AstalWindow *")] _AstalWindow* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_window_set_keymode([NativeTypeName("AstalWindow *")] _AstalWindow* self, AstalKeymode value);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("GdkMonitor *")]
        public static partial _GdkMonitor* astal_window_get_gdkmonitor([NativeTypeName("AstalWindow *")] _AstalWindow* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_window_set_gdkmonitor([NativeTypeName("AstalWindow *")] _AstalWindow* self, [NativeTypeName("GdkMonitor *")] _GdkMonitor* value);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("gint")]
        public static partial int astal_window_get_margin_top([NativeTypeName("AstalWindow *")] _AstalWindow* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_window_set_margin_top([NativeTypeName("AstalWindow *")] _AstalWindow* self, [NativeTypeName("gint")] int value);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("gint")]
        public static partial int astal_window_get_margin_bottom([NativeTypeName("AstalWindow *")] _AstalWindow* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_window_set_margin_bottom([NativeTypeName("AstalWindow *")] _AstalWindow* self, [NativeTypeName("gint")] int value);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("gint")]
        public static partial int astal_window_get_margin_left([NativeTypeName("AstalWindow *")] _AstalWindow* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_window_set_margin_left([NativeTypeName("AstalWindow *")] _AstalWindow* self, [NativeTypeName("gint")] int value);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("gint")]
        public static partial int astal_window_get_margin_right([NativeTypeName("AstalWindow *")] _AstalWindow* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_window_set_margin_right([NativeTypeName("AstalWindow *")] _AstalWindow* self, [NativeTypeName("gint")] int value);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_window_set_margin([NativeTypeName("AstalWindow *")] _AstalWindow* self, [NativeTypeName("gint")] int value);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("gint")]
        public static partial int astal_window_get_monitor([NativeTypeName("AstalWindow *")] _AstalWindow* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_window_set_monitor([NativeTypeName("AstalWindow *")] _AstalWindow* self, [NativeTypeName("gint")] int value);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_application_get_type();

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("guint")]
        public static partial uint astal_application_register_object(void* @object, [NativeTypeName("GDBusConnection *")] _GDBusConnection* connection, [NativeTypeName("const gchar *")] sbyte* path, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_application_reset_css([NativeTypeName("AstalApplication *")] _AstalApplication* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("GtkWindow *")]
        public static partial _GtkWindow* astal_application_get_window([NativeTypeName("AstalApplication *")] _AstalApplication* self, [NativeTypeName("const gchar *")] sbyte* name);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_application_apply_css([NativeTypeName("AstalApplication *")] _AstalApplication* self, [NativeTypeName("const gchar *")] sbyte* style, [NativeTypeName("gboolean")] int reset);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_application_add_icons([NativeTypeName("AstalApplication *")] _AstalApplication* self, [NativeTypeName("const gchar *")] sbyte* path);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_application_request([NativeTypeName("AstalApplication *")] _AstalApplication* self, [NativeTypeName("const gchar *")] sbyte* request, [NativeTypeName("GSocketConnection *")] _GSocketConnection* conn, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("AstalApplication *")]
        public static partial _AstalApplication* astal_application_new();

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("AstalApplication *")]
        public static partial _AstalApplication* astal_application_construct([NativeTypeName("GType")] nuint object_type);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_application_get_monitors([NativeTypeName("AstalApplication *")] _AstalApplication* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_application_get_windows([NativeTypeName("AstalApplication *")] _AstalApplication* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_application_get_gtk_theme([NativeTypeName("AstalApplication *")] _AstalApplication* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_application_set_gtk_theme([NativeTypeName("AstalApplication *")] _AstalApplication* self, [NativeTypeName("const gchar *")] sbyte* value);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_application_get_icon_theme([NativeTypeName("AstalApplication *")] _AstalApplication* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_application_set_icon_theme([NativeTypeName("AstalApplication *")] _AstalApplication* self, [NativeTypeName("const gchar *")] sbyte* value);

        [LibraryImport("/usr/lib/libastal-4.so")]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_application_get_cursor_theme([NativeTypeName("AstalApplication *")] _AstalApplication* self);

        [LibraryImport("/usr/lib/libastal-4.so")]
        public static partial void astal_application_set_cursor_theme([NativeTypeName("AstalApplication *")] _AstalApplication* self, [NativeTypeName("const gchar *")] sbyte* value);

        [NativeTypeName("#define ASTAL_MAJOR_VERSION 4")]
        public const int ASTAL_MAJOR_VERSION = 4;

        [NativeTypeName("#define ASTAL_MINOR_VERSION 0")]
        public const int ASTAL_MINOR_VERSION = 0;

        [NativeTypeName("#define ASTAL_MICRO_VERSION 0")]
        public const int ASTAL_MICRO_VERSION = 0;

        [NativeTypeName("#define ASTAL_VERSION \"4.0.0\"")]
        public static ReadOnlySpan<byte> ASTAL_VERSION => "4.0.0"u8;

        [NativeTypeName("#define ASTAL_TYPE_BIN (astal_bin_get_type ())")]
        public static readonly nuint ASTAL_TYPE_BIN = (astal_bin_get_type());

        [NativeTypeName("#define ASTAL_TYPE_BOX (astal_box_get_type ())")]
        public static readonly nuint ASTAL_TYPE_BOX = (astal_box_get_type());

        [NativeTypeName("#define ASTAL_TYPE_SLIDER (astal_slider_get_type ())")]
        public static readonly nuint ASTAL_TYPE_SLIDER = (astal_slider_get_type());

        [NativeTypeName("#define ASTAL_TYPE_WINDOW_ANCHOR (astal_window_anchor_get_type ())")]
        public static readonly nuint ASTAL_TYPE_WINDOW_ANCHOR = (astal_window_anchor_get_type());

        [NativeTypeName("#define ASTAL_TYPE_EXCLUSIVITY (astal_exclusivity_get_type ())")]
        public static readonly nuint ASTAL_TYPE_EXCLUSIVITY = (astal_exclusivity_get_type());

        [NativeTypeName("#define ASTAL_TYPE_LAYER (astal_layer_get_type ())")]
        public static readonly nuint ASTAL_TYPE_LAYER = (astal_layer_get_type());

        [NativeTypeName("#define ASTAL_TYPE_KEYMODE (astal_keymode_get_type ())")]
        public static readonly nuint ASTAL_TYPE_KEYMODE = (astal_keymode_get_type());

        [NativeTypeName("#define ASTAL_TYPE_WINDOW (astal_window_get_type ())")]
        public static readonly nuint ASTAL_TYPE_WINDOW = (astal_window_get_type());

        [NativeTypeName("#define ASTAL_TYPE_APPLICATION (astal_application_get_type ())")]
        public static readonly nuint ASTAL_TYPE_APPLICATION = (astal_application_get_type());
    }
}
