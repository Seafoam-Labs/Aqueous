using System;
using System.Runtime.InteropServices;
namespace Aqueous.Bindings.AstalGreet
{
    public static unsafe partial class AstalGreetInterop
    {
        private const string LibName = "libastal-greet.so";

        // Free functions
        [LibraryImport(LibName)]
        public static partial void astal_greet_login([NativeTypeName("const gchar *")] sbyte* username, [NativeTypeName("const gchar *")] sbyte* password, [NativeTypeName("const gchar *")] sbyte* cmd, [NativeTypeName("GAsyncReadyCallback")] IntPtr callback, [NativeTypeName("gpointer")] IntPtr user_data);

        [LibraryImport(LibName)]
        public static partial void astal_greet_login_finish([NativeTypeName("GAsyncResult *")] _GAsyncResult* res, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        public static partial void astal_greet_login_with_env([NativeTypeName("const gchar *")] sbyte* username, [NativeTypeName("const gchar *")] sbyte* password, [NativeTypeName("const gchar *")] sbyte* cmd, [NativeTypeName("gchar **")] sbyte** env, [NativeTypeName("gint")] int env_length1, [NativeTypeName("GAsyncReadyCallback")] IntPtr callback, [NativeTypeName("gpointer")] IntPtr user_data);

        [LibraryImport(LibName)]
        public static partial void astal_greet_login_with_env_finish([NativeTypeName("GAsyncResult *")] _GAsyncResult* res, [NativeTypeName("GError **")] _GError** error);

        // Request
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_greet_request_get_type();

        [LibraryImport(LibName)]
        public static partial void astal_greet_request_send([NativeTypeName("AstalGreetRequest *")] _AstalGreetRequest* self, [NativeTypeName("GAsyncReadyCallback")] IntPtr callback, [NativeTypeName("gpointer")] IntPtr user_data);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalGreetResponse *")]
        public static partial _AstalGreetResponse* astal_greet_request_send_finish([NativeTypeName("AstalGreetRequest *")] _AstalGreetRequest* self, [NativeTypeName("GAsyncResult *")] _GAsyncResult* res, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalGreetRequest *")]
        public static partial _AstalGreetRequest* astal_greet_request_construct([NativeTypeName("GType")] nuint object_type);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_greet_request_get_type_name([NativeTypeName("AstalGreetRequest *")] _AstalGreetRequest* self);

        // CreateSession
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_greet_create_session_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalGreetCreateSession *")]
        public static partial _AstalGreetCreateSession* astal_greet_create_session_new([NativeTypeName("const gchar *")] sbyte* username);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_greet_create_session_get_username([NativeTypeName("AstalGreetCreateSession *")] _AstalGreetCreateSession* self);

        [LibraryImport(LibName)]
        public static partial void astal_greet_create_session_set_username([NativeTypeName("AstalGreetCreateSession *")] _AstalGreetCreateSession* self, [NativeTypeName("const gchar *")] sbyte* value);

        // PostAuthMesssage (note: triple 's' in original API)
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_greet_post_auth_messsage_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalGreetPostAuthMesssage *")]
        public static partial _AstalGreetPostAuthMesssage* astal_greet_post_auth_messsage_new([NativeTypeName("const gchar *")] sbyte* response);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_greet_post_auth_messsage_get_response([NativeTypeName("AstalGreetPostAuthMesssage *")] _AstalGreetPostAuthMesssage* self);

        [LibraryImport(LibName)]
        public static partial void astal_greet_post_auth_messsage_set_response([NativeTypeName("AstalGreetPostAuthMesssage *")] _AstalGreetPostAuthMesssage* self, [NativeTypeName("const gchar *")] sbyte* value);

        // StartSession
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_greet_start_session_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalGreetStartSession *")]
        public static partial _AstalGreetStartSession* astal_greet_start_session_new([NativeTypeName("gchar **")] sbyte** cmd, [NativeTypeName("gint")] int cmd_length1, [NativeTypeName("gchar **")] sbyte** env, [NativeTypeName("gint")] int env_length1);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar **")]
        public static partial sbyte** astal_greet_start_session_get_cmd([NativeTypeName("AstalGreetStartSession *")] _AstalGreetStartSession* self, [NativeTypeName("gint *")] int* result_length1);

        [LibraryImport(LibName)]
        public static partial void astal_greet_start_session_set_cmd([NativeTypeName("AstalGreetStartSession *")] _AstalGreetStartSession* self, [NativeTypeName("gchar **")] sbyte** value, [NativeTypeName("gint")] int value_length1);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar **")]
        public static partial sbyte** astal_greet_start_session_get_env([NativeTypeName("AstalGreetStartSession *")] _AstalGreetStartSession* self, [NativeTypeName("gint *")] int* result_length1);

        [LibraryImport(LibName)]
        public static partial void astal_greet_start_session_set_env([NativeTypeName("AstalGreetStartSession *")] _AstalGreetStartSession* self, [NativeTypeName("gchar **")] sbyte** value, [NativeTypeName("gint")] int value_length1);

        // CancelSession
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_greet_cancel_session_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalGreetCancelSession *")]
        public static partial _AstalGreetCancelSession* astal_greet_cancel_session_new();

        // Response
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_greet_response_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalGreetResponse *")]
        public static partial _AstalGreetResponse* astal_greet_response_construct([NativeTypeName("GType")] nuint object_type);

        // Success
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_greet_success_get_type();

        // Error
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_greet_error_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_greet_error_type_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalGreetErrorType")]
        public static partial int astal_greet_error_get_error_type([NativeTypeName("AstalGreetError *")] _AstalGreetError* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_greet_error_get_description([NativeTypeName("AstalGreetError *")] _AstalGreetError* self);

        // AuthMessage
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_greet_auth_message_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_greet_auth_message_type_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalGreetAuthMessageType")]
        public static partial int astal_greet_auth_message_get_message_type([NativeTypeName("AstalGreetAuthMessage *")] _AstalGreetAuthMessage* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_greet_auth_message_get_message([NativeTypeName("AstalGreetAuthMessage *")] _AstalGreetAuthMessage* self);
    }
}
