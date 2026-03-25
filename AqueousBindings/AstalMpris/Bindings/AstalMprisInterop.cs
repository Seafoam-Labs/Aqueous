using System;
using System.Runtime.InteropServices;
namespace Aqueous.Bindings.AstalMpris
{
    public static unsafe partial class AstalMprisInterop
    {
        private const string LibName = "libastal-mpris.so";

        // AstalMprisMpris
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_mpris_mpris_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalMprisMpris *")]
        public static partial _AstalMprisMpris* astal_mpris_get_default();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalMprisMpris *")]
        public static partial _AstalMprisMpris* astal_mpris_mpris_get_default();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalMprisMpris *")]
        public static partial _AstalMprisMpris* astal_mpris_mpris_new();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalMprisMpris *")]
        public static partial _AstalMprisMpris* astal_mpris_mpris_construct([NativeTypeName("GType")] nuint object_type);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_mpris_mpris_get_players([NativeTypeName("AstalMprisMpris *")] _AstalMprisMpris* self);

        // Enum GType getters
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_mpris_loop_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_mpris_shuffle_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_mpris_playback_status_get_type();

        // AstalMprisPlayer
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_mpris_player_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalMprisPlayer *")]
        public static partial _AstalMprisPlayer* astal_mpris_player_new([NativeTypeName("const gchar *")] sbyte* name);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalMprisPlayer *")]
        public static partial _AstalMprisPlayer* astal_mpris_player_construct([NativeTypeName("GType")] nuint object_type, [NativeTypeName("const gchar *")] sbyte* name);

        // Player methods
        [LibraryImport(LibName)]
        public static partial void astal_mpris_player_raise([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        public static partial void astal_mpris_player_quit([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        public static partial void astal_mpris_player_toggle_fullscreen([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        public static partial void astal_mpris_player_next([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        public static partial void astal_mpris_player_previous([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        public static partial void astal_mpris_player_pause([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        public static partial void astal_mpris_player_play_pause([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        public static partial void astal_mpris_player_stop([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        public static partial void astal_mpris_player_play([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        public static partial void astal_mpris_player_open_uri([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self, [NativeTypeName("const gchar *")] sbyte* uri);

        [LibraryImport(LibName)]
        public static partial void astal_mpris_player_loop([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        public static partial void astal_mpris_player_shuffle([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GVariant *")]
        public static partial _GVariant* astal_mpris_player_get_meta([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self, [NativeTypeName("const gchar *")] sbyte* key);

        // Player property getters
        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_mpris_player_get_bus_name([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_mpris_player_get_available([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_mpris_player_get_can_quit([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_mpris_player_get_fullscreen([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_mpris_player_get_can_set_fullscreen([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_mpris_player_get_can_raise([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_mpris_player_get_identity([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_mpris_player_get_entry([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar **")]
        public static partial sbyte** astal_mpris_player_get_supported_uri_schemes([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self, [NativeTypeName("gint *")] int* result_length1);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar **")]
        public static partial sbyte** astal_mpris_player_get_supported_mime_types([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self, [NativeTypeName("gint *")] int* result_length1);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalMprisLoop")]
        public static partial int astal_mpris_player_get_loop_status([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        public static partial void astal_mpris_player_set_loop_status([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self, [NativeTypeName("AstalMprisLoop")] int value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalMprisShuffle")]
        public static partial int astal_mpris_player_get_shuffle_status([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        public static partial void astal_mpris_player_set_shuffle_status([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self, [NativeTypeName("AstalMprisShuffle")] int value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_mpris_player_get_rate([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        public static partial void astal_mpris_player_set_rate([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self, [NativeTypeName("gdouble")] double value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_mpris_player_get_volume([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        public static partial void astal_mpris_player_set_volume([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self, [NativeTypeName("gdouble")] double value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_mpris_player_get_position([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        public static partial void astal_mpris_player_set_position([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self, [NativeTypeName("gdouble")] double value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalMprisPlaybackStatus")]
        public static partial int astal_mpris_player_get_playback_status([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_mpris_player_get_minimum_rate([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_mpris_player_get_maximum_rate([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_mpris_player_get_can_go_next([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_mpris_player_get_can_go_previous([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_mpris_player_get_can_play([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_mpris_player_get_can_pause([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_mpris_player_get_can_seek([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_mpris_player_get_can_control([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GVariant *")]
        public static partial _GVariant* astal_mpris_player_get_metadata([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_mpris_player_get_trackid([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_mpris_player_get_length([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_mpris_player_get_art_url([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_mpris_player_get_album([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_mpris_player_get_album_artist([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_mpris_player_get_artist([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_mpris_player_get_lyrics([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_mpris_player_get_title([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_mpris_player_get_composer([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_mpris_player_get_comments([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_mpris_player_get_cover_art([NativeTypeName("AstalMprisPlayer *")] _AstalMprisPlayer* self);
    }
}
