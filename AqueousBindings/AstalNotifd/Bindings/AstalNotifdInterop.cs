using System;
using System.Runtime.InteropServices;
namespace Aqueous.Bindings.AstalNotifd
{
    public static unsafe partial class AstalNotifdInterop
    {
        private const string LibName = "libastal-notifd.so";

        // AstalNotifdAction
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_notifd_action_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNotifdAction *")]
        public static partial _AstalNotifdAction* astal_notifd_action_new([NativeTypeName("const gchar *")] sbyte* id, [NativeTypeName("const gchar *")] sbyte* label);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNotifdAction *")]
        public static partial _AstalNotifdAction* astal_notifd_action_construct([NativeTypeName("GType")] nuint object_type, [NativeTypeName("const gchar *")] sbyte* id, [NativeTypeName("const gchar *")] sbyte* label);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_action_invoke([NativeTypeName("AstalNotifdAction *")] _AstalNotifdAction* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_notifd_action_get_id([NativeTypeName("AstalNotifdAction *")] _AstalNotifdAction* self);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_action_set_id([NativeTypeName("AstalNotifdAction *")] _AstalNotifdAction* self, [NativeTypeName("const gchar *")] sbyte* value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_notifd_action_get_label([NativeTypeName("AstalNotifdAction *")] _AstalNotifdAction* self);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_action_set_label([NativeTypeName("AstalNotifdAction *")] _AstalNotifdAction* self, [NativeTypeName("const gchar *")] sbyte* value);

        // Enums
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_notifd_urgency_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_notifd_closed_reason_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_notifd_state_get_type();

        // AstalNotifdNotifd
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_notifd_notifd_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNotifdNotifd *")]
        public static partial _AstalNotifdNotifd* astal_notifd_get_default();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNotifdNotifd *")]
        public static partial _AstalNotifdNotifd* astal_notifd_notifd_get_default();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNotifdNotification *")]
        public static partial _AstalNotifdNotification* astal_notifd_notifd_get_notification([NativeTypeName("AstalNotifdNotifd *")] _AstalNotifdNotifd* self, [NativeTypeName("guint")] uint id);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNotifdNotifd *")]
        public static partial _AstalNotifdNotifd* astal_notifd_notifd_new();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNotifdNotifd *")]
        public static partial _AstalNotifdNotifd* astal_notifd_notifd_construct([NativeTypeName("GType")] nuint object_type);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_notifd_notifd_get_ignore_timeout([NativeTypeName("AstalNotifdNotifd *")] _AstalNotifdNotifd* self);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_notifd_set_ignore_timeout([NativeTypeName("AstalNotifdNotifd *")] _AstalNotifdNotifd* self, [NativeTypeName("gboolean")] int value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_notifd_notifd_get_dont_disturb([NativeTypeName("AstalNotifdNotifd *")] _AstalNotifdNotifd* self);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_notifd_set_dont_disturb([NativeTypeName("AstalNotifdNotifd *")] _AstalNotifdNotifd* self, [NativeTypeName("gboolean")] int value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint")]
        public static partial int astal_notifd_notifd_get_default_timeout([NativeTypeName("AstalNotifdNotifd *")] _AstalNotifdNotifd* self);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_notifd_set_default_timeout([NativeTypeName("AstalNotifdNotifd *")] _AstalNotifdNotifd* self, [NativeTypeName("gint")] int value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_notifd_notifd_get_notifications([NativeTypeName("AstalNotifdNotifd *")] _AstalNotifdNotifd* self);

        // AstalNotifdNotification
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_notifd_notification_get_type();

        [LibraryImport(LibName)]
        public static partial void astal_notifd_notification_dismiss([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_notification_expire([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_notification_invoke([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self, [NativeTypeName("const gchar *")] sbyte* action_id);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNotifdNotification *")]
        public static partial _AstalNotifdNotification* astal_notifd_notification_add_action([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self, [NativeTypeName("AstalNotifdAction *")] _AstalNotifdAction* action);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNotifdNotification *")]
        public static partial _AstalNotifdNotification* astal_notifd_notification_set_hint([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self, [NativeTypeName("const gchar *")] sbyte* name, [NativeTypeName("GVariant *")] _GVariant* value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GVariant *")]
        public static partial _GVariant* astal_notifd_notification_get_hint([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self, [NativeTypeName("const gchar *")] sbyte* name);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNotifdNotification *")]
        public static partial _AstalNotifdNotification* astal_notifd_notification_new();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNotifdNotification *")]
        public static partial _AstalNotifdNotification* astal_notifd_notification_construct([NativeTypeName("GType")] nuint object_type);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNotifdState")]
        public static partial int astal_notifd_notification_get_state([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint64")]
        public static partial long astal_notifd_notification_get_time([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("guint32")]
        public static partial uint astal_notifd_notification_get_id([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_notification_set_id([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self, [NativeTypeName("guint32")] uint value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_notifd_notification_get_app_name([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_notification_set_app_name([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self, [NativeTypeName("const gchar *")] sbyte* value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_notifd_notification_get_app_icon([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_notification_set_app_icon([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self, [NativeTypeName("const gchar *")] sbyte* value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_notifd_notification_get_summary([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_notification_set_summary([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self, [NativeTypeName("const gchar *")] sbyte* value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_notifd_notification_get_body([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_notification_set_body([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self, [NativeTypeName("const gchar *")] sbyte* value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint32")]
        public static partial int astal_notifd_notification_get_expire_timeout([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_notification_set_expire_timeout([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self, [NativeTypeName("gint32")] int value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_notifd_notification_get_actions([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GVariant *")]
        public static partial _GVariant* astal_notifd_notification_get_hints([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_notifd_notification_get_image([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_notification_set_image([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self, [NativeTypeName("const gchar *")] sbyte* value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_notifd_notification_get_action_icons([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_notification_set_action_icons([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self, [NativeTypeName("gboolean")] int value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_notifd_notification_get_category([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_notification_set_category([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self, [NativeTypeName("const gchar *")] sbyte* value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_notifd_notification_get_desktop_entry([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_notification_set_desktop_entry([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self, [NativeTypeName("const gchar *")] sbyte* value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_notifd_notification_get_resident([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_notification_set_resident([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self, [NativeTypeName("gboolean")] int value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_notifd_notification_get_sound_file([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_notification_set_sound_file([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self, [NativeTypeName("const gchar *")] sbyte* value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_notifd_notification_get_sound_name([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_notification_set_sound_name([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self, [NativeTypeName("const gchar *")] sbyte* value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_notifd_notification_get_suppress_sound([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_notification_set_suppress_sound([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self, [NativeTypeName("gboolean")] int value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_notifd_notification_get_transient([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_notification_set_transient([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self, [NativeTypeName("gboolean")] int value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint")]
        public static partial int astal_notifd_notification_get_x([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_notification_set_x([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self, [NativeTypeName("gint")] int value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint")]
        public static partial int astal_notifd_notification_get_y([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_notification_set_y([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self, [NativeTypeName("gint")] int value);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalNotifdUrgency")]
        public static partial int astal_notifd_notification_get_urgency([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_notification_set_urgency([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* self, [NativeTypeName("AstalNotifdUrgency")] int value);

        // Free function
        [LibraryImport(LibName)]
        public static partial void astal_notifd_send_notification([NativeTypeName("AstalNotifdNotification *")] _AstalNotifdNotification* notification, [NativeTypeName("GAsyncReadyCallback")] IntPtr _callback_, [NativeTypeName("gpointer")] IntPtr _user_data_);

        [LibraryImport(LibName)]
        public static partial void astal_notifd_send_notification_finish([NativeTypeName("GAsyncResult *")] _GAsyncResult* _res_, [NativeTypeName("GError **")] _GError** error);
    }
}
