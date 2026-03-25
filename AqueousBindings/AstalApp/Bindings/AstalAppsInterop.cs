using System;
using System.Runtime.InteropServices;

namespace Aqueous.Bindings.AstalApp
{
    public static unsafe partial class AstalAppsInterop
    {
        private const string LibName = "libastal-apps.so";

        // AstalAppsApplication
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_apps_application_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalAppsApplication *")]
        public static partial _AstalAppsApplication* astal_apps_application_new();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalAppsApplication *")]
        public static partial _AstalAppsApplication* astal_apps_application_construct([NativeTypeName("GType")] nuint object_type);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GDesktopAppInfo *")]
        public static partial _GDesktopAppInfo* astal_apps_application_get_app([NativeTypeName("AstalAppsApplication *")] _AstalAppsApplication* self);

        [LibraryImport(LibName)]
        public static partial void astal_apps_application_set_app([NativeTypeName("AstalAppsApplication *")] _AstalAppsApplication* self, [NativeTypeName("GDesktopAppInfo *")] _GDesktopAppInfo* value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_apps_application_get_name([NativeTypeName("AstalAppsApplication *")] _AstalAppsApplication* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_apps_application_get_description([NativeTypeName("AstalAppsApplication *")] _AstalAppsApplication* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_apps_application_get_executable([NativeTypeName("AstalAppsApplication *")] _AstalAppsApplication* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_apps_application_get_icon_name([NativeTypeName("AstalAppsApplication *")] _AstalAppsApplication* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_apps_application_get_wm_class([NativeTypeName("AstalAppsApplication *")] _AstalAppsApplication* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_apps_application_get_entry([NativeTypeName("AstalAppsApplication *")] _AstalAppsApplication* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_apps_application_get_key([NativeTypeName("AstalAppsApplication *")] _AstalAppsApplication* self, [NativeTypeName("const gchar *")] sbyte* key);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar **")]
        public static partial sbyte** astal_apps_application_get_categories([NativeTypeName("AstalAppsApplication *")] _AstalAppsApplication* self, [NativeTypeName("gint *")] int* result_length1);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar **")]
        public static partial sbyte** astal_apps_application_get_keywords([NativeTypeName("AstalAppsApplication *")] _AstalAppsApplication* self, [NativeTypeName("gint *")] int* result_length1);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint")]
        public static partial int astal_apps_application_get_frequency([NativeTypeName("AstalAppsApplication *")] _AstalAppsApplication* self);

        [LibraryImport(LibName)]
        public static partial void astal_apps_application_set_frequency([NativeTypeName("AstalAppsApplication *")] _AstalAppsApplication* self, [NativeTypeName("gint")] int value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_apps_application_launch([NativeTypeName("AstalAppsApplication *")] _AstalAppsApplication* self);

        [LibraryImport(LibName)]
        public static partial void astal_apps_application_exact_match([NativeTypeName("AstalAppsApplication *")] _AstalAppsApplication* self, [NativeTypeName("const gchar *")] sbyte* query, [NativeTypeName("AstalAppsScore *")] _AstalAppsScore* result);

        [LibraryImport(LibName)]
        public static partial void astal_apps_application_fuzzy_match([NativeTypeName("AstalAppsApplication *")] _AstalAppsApplication* self, [NativeTypeName("const gchar *")] sbyte* query, [NativeTypeName("AstalAppsScore *")] _AstalAppsScore* result);

        // AstalAppsApps
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_apps_apps_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalAppsApps *")]
        public static partial _AstalAppsApps* astal_apps_apps_new();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalAppsApps *")]
        public static partial _AstalAppsApps* astal_apps_apps_construct([NativeTypeName("GType")] nuint object_type);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_apps_apps_get_list([NativeTypeName("AstalAppsApps *")] _AstalAppsApps* self);

        [LibraryImport(LibName)]
        public static partial void astal_apps_apps_reload([NativeTypeName("AstalAppsApps *")] _AstalAppsApps* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_apps_apps_fuzzy_query([NativeTypeName("AstalAppsApps *")] _AstalAppsApps* self, [NativeTypeName("const gchar *")] sbyte* query);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_apps_apps_exact_query([NativeTypeName("AstalAppsApps *")] _AstalAppsApps* self, [NativeTypeName("const gchar *")] sbyte* query);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_apps_apps_fuzzy_score([NativeTypeName("AstalAppsApps *")] _AstalAppsApps* self, [NativeTypeName("const gchar *")] sbyte* query, [NativeTypeName("AstalAppsApplication *")] _AstalAppsApplication* a);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_apps_apps_exact_score([NativeTypeName("AstalAppsApps *")] _AstalAppsApps* self, [NativeTypeName("const gchar *")] sbyte* query, [NativeTypeName("AstalAppsApplication *")] _AstalAppsApplication* a);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_apps_apps_get_show_hidden([NativeTypeName("AstalAppsApps *")] _AstalAppsApps* self);

        [LibraryImport(LibName)]
        public static partial void astal_apps_apps_set_show_hidden([NativeTypeName("AstalAppsApps *")] _AstalAppsApps* self, [NativeTypeName("gboolean")] int value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_apps_apps_get_min_score([NativeTypeName("AstalAppsApps *")] _AstalAppsApps* self);

        [LibraryImport(LibName)]
        public static partial void astal_apps_apps_set_min_score([NativeTypeName("AstalAppsApps *")] _AstalAppsApps* self, [NativeTypeName("gdouble")] double value);

        // Multipliers
        [LibraryImport(LibName)] public static partial double astal_apps_apps_get_name_multiplier([NativeTypeName("AstalAppsApps *")] _AstalAppsApps* self);
        [LibraryImport(LibName)] public static partial void astal_apps_apps_set_name_multiplier([NativeTypeName("AstalAppsApps *")] _AstalAppsApps* self, double value);
        [LibraryImport(LibName)] public static partial double astal_apps_apps_get_entry_multiplier([NativeTypeName("AstalAppsApps *")] _AstalAppsApps* self);
        [LibraryImport(LibName)] public static partial void astal_apps_apps_set_entry_multiplier([NativeTypeName("AstalAppsApps *")] _AstalAppsApps* self, double value);
        [LibraryImport(LibName)] public static partial double astal_apps_apps_get_executable_multiplier([NativeTypeName("AstalAppsApps *")] _AstalAppsApps* self);
        [LibraryImport(LibName)] public static partial void astal_apps_apps_set_executable_multiplier([NativeTypeName("AstalAppsApps *")] _AstalAppsApps* self, double value);
        [LibraryImport(LibName)] public static partial double astal_apps_apps_get_description_multiplier([NativeTypeName("AstalAppsApps *")] _AstalAppsApps* self);
        [LibraryImport(LibName)] public static partial void astal_apps_apps_set_description_multiplier([NativeTypeName("AstalAppsApps *")] _AstalAppsApps* self, double value);
        [LibraryImport(LibName)] public static partial double astal_apps_apps_get_keywords_multiplier([NativeTypeName("AstalAppsApps *")] _AstalAppsApps* self);
        [LibraryImport(LibName)] public static partial void astal_apps_apps_set_keywords_multiplier([NativeTypeName("AstalAppsApps *")] _AstalAppsApps* self, double value);
        [LibraryImport(LibName)] public static partial double astal_apps_apps_get_categories_multiplier([NativeTypeName("AstalAppsApps *")] _AstalAppsApps* self);
        [LibraryImport(LibName)] public static partial void astal_apps_apps_set_categories_multiplier([NativeTypeName("AstalAppsApps *")] _AstalAppsApps* self, double value);

        // Score
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_apps_score_get_type();

        [LibraryImport(LibName)]
        public static partial void astal_apps_score_free([NativeTypeName("AstalAppsScore *")] _AstalAppsScore* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalAppsScore *")]
        public static partial _AstalAppsScore* astal_apps_score_dup([NativeTypeName("AstalAppsScore *")] _AstalAppsScore* self);

        // Enums
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_apps_search_algorithm_get_type();
    }
}
