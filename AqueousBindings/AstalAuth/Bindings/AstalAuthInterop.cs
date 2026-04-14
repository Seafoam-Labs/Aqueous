using System;
using System.Runtime.InteropServices;

namespace Aqueous.Bindings.AstalAuth
{
    public static unsafe partial class AstalAuthInterop
    {
        private const string LibName = "libastal-auth.so";
        private const string GObjectLib = "libgobject-2.0.so";

        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_auth_pam_get_type();

        [DllImport(GObjectLib)]
        public static extern IntPtr g_object_new(nuint object_type, IntPtr first_property_name);

        [DllImport(GObjectLib)]
        public static extern ulong g_signal_connect_data(
            IntPtr instance, IntPtr detailed_signal, IntPtr c_handler,
            IntPtr data, IntPtr destroy_data, int connect_flags);

        [DllImport(GObjectLib)]
        public static extern void g_signal_handler_disconnect(IntPtr instance, ulong handler_id);

        [LibraryImport(LibName)]
        public static partial void astal_auth_pam_set_username([NativeTypeName("AstalAuthPam *")] _AstalAuthPam* self, [NativeTypeName("const gchar *")] sbyte* username);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_auth_pam_get_username([NativeTypeName("AstalAuthPam *")] _AstalAuthPam* self);

        [LibraryImport(LibName)]
        public static partial void astal_auth_pam_set_service([NativeTypeName("AstalAuthPam *")] _AstalAuthPam* self, [NativeTypeName("const gchar *")] sbyte* service);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_auth_pam_get_service([NativeTypeName("AstalAuthPam *")] _AstalAuthPam* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_auth_pam_start_authenticate([NativeTypeName("AstalAuthPam *")] _AstalAuthPam* self);

        [LibraryImport(LibName)]
        public static partial void astal_auth_pam_supply_secret([NativeTypeName("AstalAuthPam *")] _AstalAuthPam* self, [NativeTypeName("const gchar *")] sbyte* secret);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_auth_pam_authenticate([NativeTypeName("const gchar *")] sbyte* password, [NativeTypeName("GAsyncReadyCallback")] IntPtr result_callback, [NativeTypeName("gpointer")] IntPtr user_data);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gssize")]
        public static partial nint astal_auth_pam_authenticate_finish([NativeTypeName("GAsyncResult *")] _GAsyncResult* res, [NativeTypeName("GError **")] _GError** error);
    }
}
