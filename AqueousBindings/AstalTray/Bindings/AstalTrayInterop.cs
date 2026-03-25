using System;
using System.Runtime.InteropServices;
namespace Aqueous.Bindings.AstalTray
{
    public static unsafe partial class AstalTrayInterop
    {
        private const string LibName = "libastal-tray.so";

        // Enums
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_tray_category_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_tray_status_get_type();

        // AstalTrayTrayItem
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_tray_tray_item_get_type();

        [LibraryImport(LibName)]
        public static partial void astal_tray_tray_item_about_to_show([NativeTypeName("AstalTrayTrayItem *")] _AstalTrayTrayItem* self);

        [LibraryImport(LibName)]
        public static partial void astal_tray_tray_item_activate([NativeTypeName("AstalTrayTrayItem *")] _AstalTrayTrayItem* self, [NativeTypeName("gint")] int x, [NativeTypeName("gint")] int y);

        [LibraryImport(LibName)]
        public static partial void astal_tray_tray_item_secondary_activate([NativeTypeName("AstalTrayTrayItem *")] _AstalTrayTrayItem* self, [NativeTypeName("gint")] int x, [NativeTypeName("gint")] int y);

        [LibraryImport(LibName)]
        public static partial void astal_tray_tray_item_scroll([NativeTypeName("AstalTrayTrayItem *")] _AstalTrayTrayItem* self, [NativeTypeName("gint")] int delta, [NativeTypeName("const gchar *")] sbyte* orientation);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_tray_tray_item_to_json_string([NativeTypeName("AstalTrayTrayItem *")] _AstalTrayTrayItem* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_tray_tray_item_get_title([NativeTypeName("AstalTrayTrayItem *")] _AstalTrayTrayItem* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalTrayCategory")]
        public static partial int astal_tray_tray_item_get_category([NativeTypeName("AstalTrayTrayItem *")] _AstalTrayTrayItem* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalTrayStatus")]
        public static partial int astal_tray_tray_item_get_status([NativeTypeName("AstalTrayTrayItem *")] _AstalTrayTrayItem* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_tray_tray_item_get_tooltip_markup([NativeTypeName("AstalTrayTrayItem *")] _AstalTrayTrayItem* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_tray_tray_item_get_tooltip_text([NativeTypeName("AstalTrayTrayItem *")] _AstalTrayTrayItem* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_tray_tray_item_get_id([NativeTypeName("AstalTrayTrayItem *")] _AstalTrayTrayItem* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_tray_tray_item_get_is_menu([NativeTypeName("AstalTrayTrayItem *")] _AstalTrayTrayItem* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_tray_tray_item_get_icon_theme_path([NativeTypeName("AstalTrayTrayItem *")] _AstalTrayTrayItem* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_tray_tray_item_get_icon_name([NativeTypeName("AstalTrayTrayItem *")] _AstalTrayTrayItem* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GdkPixbuf *")]
        public static partial _GdkPixbuf* astal_tray_tray_item_get_icon_pixbuf([NativeTypeName("AstalTrayTrayItem *")] _AstalTrayTrayItem* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GIcon *")]
        public static partial _GIcon* astal_tray_tray_item_get_gicon([NativeTypeName("AstalTrayTrayItem *")] _AstalTrayTrayItem* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_tray_tray_item_get_item_id([NativeTypeName("AstalTrayTrayItem *")] _AstalTrayTrayItem* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const char *")]
        public static partial sbyte* astal_tray_tray_item_get_menu_path([NativeTypeName("AstalTrayTrayItem *")] _AstalTrayTrayItem* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GMenuModel *")]
        public static partial _GMenuModel* astal_tray_tray_item_get_menu_model([NativeTypeName("AstalTrayTrayItem *")] _AstalTrayTrayItem* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GActionGroup *")]
        public static partial _GActionGroup* astal_tray_tray_item_get_action_group([NativeTypeName("AstalTrayTrayItem *")] _AstalTrayTrayItem* self);

        // AstalTrayTray
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_tray_tray_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalTrayTray *")]
        public static partial _AstalTrayTray* astal_tray_get_default();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalTrayTray *")]
        public static partial _AstalTrayTray* astal_tray_tray_get_default();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalTrayTrayItem *")]
        public static partial _AstalTrayTrayItem* astal_tray_tray_get_item([NativeTypeName("AstalTrayTray *")] _AstalTrayTray* self, [NativeTypeName("const gchar *")] sbyte* item_id);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalTrayTray *")]
        public static partial _AstalTrayTray* astal_tray_tray_new();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalTrayTray *")]
        public static partial _AstalTrayTray* astal_tray_tray_construct([NativeTypeName("GType")] nuint object_type);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_tray_tray_get_items([NativeTypeName("AstalTrayTray *")] _AstalTrayTray* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GListModel *")]
        public static partial _GListModel* astal_tray_tray_get_items_model([NativeTypeName("AstalTrayTray *")] _AstalTrayTray* self);
    }
}
