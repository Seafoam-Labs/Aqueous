using System;
using System.Runtime.InteropServices;
namespace Aqueous.Bindings.AstalIo
{
    public static unsafe partial class AstalIoInterop
    {
        private const string LibName = "libastal-io.so";

        // AstalIOAppError enum
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_io_app_error_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("GQuark")]
        public static partial uint astal_io_app_error_quark();

        // AstalIOApplication (interface)
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_io_application_get_type();

        [LibraryImport(LibName)]
        public static partial void astal_io_application_quit([NativeTypeName("AstalIOApplication *")] void* self, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        public static partial void astal_io_application_inspector([NativeTypeName("AstalIOApplication *")] void* self, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        public static partial void astal_io_application_toggle_window([NativeTypeName("AstalIOApplication *")] void* self, [NativeTypeName("const gchar *")] sbyte* window, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        public static partial void astal_io_application_acquire_socket([NativeTypeName("AstalIOApplication *")] void* self, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        public static partial void astal_io_application_request([NativeTypeName("AstalIOApplication *")] void* self, [NativeTypeName("const gchar *")] sbyte* request, [NativeTypeName("GSocketConnection *")] _GSocketConnection* conn, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_io_application_get_instance_name([NativeTypeName("AstalIOApplication *")] void* self);

        [LibraryImport(LibName)]
        public static partial void astal_io_application_set_instance_name([NativeTypeName("AstalIOApplication *")] void* self, [NativeTypeName("const gchar *")] sbyte* value);

        // Free functions
        [LibraryImport(LibName)]
        [return: NativeTypeName("GSocketService *")]
        public static partial _GSocketService* astal_io_acquire_socket([NativeTypeName("AstalIOApplication *")] void* app, [NativeTypeName("gchar **")] sbyte** sock, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_io_get_instances();

        [LibraryImport(LibName)]
        public static partial void astal_io_quit_instance([NativeTypeName("const gchar *")] sbyte* instance, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        public static partial void astal_io_open_inspector([NativeTypeName("const gchar *")] sbyte* instance, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        public static partial void astal_io_toggle_window_by_name([NativeTypeName("const gchar *")] sbyte* instance, [NativeTypeName("const gchar *")] sbyte* window, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_io_send_message([NativeTypeName("const gchar *")] sbyte* instance, [NativeTypeName("const gchar *")] sbyte* request, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_io_send_request([NativeTypeName("const gchar *")] sbyte* instance, [NativeTypeName("const gchar *")] sbyte* request, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        public static partial void astal_io_read_sock([NativeTypeName("GSocketConnection *")] _GSocketConnection* conn, [NativeTypeName("GAsyncReadyCallback")] void* _callback_, [NativeTypeName("gpointer")] void* _user_data_);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_io_read_sock_finish([NativeTypeName("GAsyncResult *")] _GAsyncResult* _res_, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        public static partial void astal_io_write_sock([NativeTypeName("GSocketConnection *")] _GSocketConnection* conn, [NativeTypeName("const gchar *")] sbyte* response, [NativeTypeName("GAsyncReadyCallback")] void* _callback_, [NativeTypeName("gpointer")] void* _user_data_);

        [LibraryImport(LibName)]
        public static partial void astal_io_write_sock_finish([NativeTypeName("GAsyncResult *")] _GAsyncResult* _res_, [NativeTypeName("GError **")] _GError** error);

        // File utilities (deprecated)
        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_io_read_file([NativeTypeName("const gchar *")] sbyte* path);

        [LibraryImport(LibName)]
        public static partial void astal_io_read_file_async([NativeTypeName("const gchar *")] sbyte* path, [NativeTypeName("GAsyncReadyCallback")] void* _callback_, [NativeTypeName("gpointer")] void* _user_data_);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_io_read_file_finish([NativeTypeName("GAsyncResult *")] _GAsyncResult* _res_, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        public static partial void astal_io_write_file([NativeTypeName("const gchar *")] sbyte* path, [NativeTypeName("const gchar *")] sbyte* content);

        [LibraryImport(LibName)]
        public static partial void astal_io_write_file_async([NativeTypeName("const gchar *")] sbyte* path, [NativeTypeName("const gchar *")] sbyte* content, [NativeTypeName("GAsyncReadyCallback")] void* _callback_, [NativeTypeName("gpointer")] void* _user_data_);

        [LibraryImport(LibName)]
        public static partial void astal_io_write_file_finish([NativeTypeName("GAsyncResult *")] _GAsyncResult* _res_, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GFileMonitor *")]
        public static partial _GFileMonitor* astal_io_monitor_file([NativeTypeName("const gchar *")] sbyte* path, [NativeTypeName("GClosure *")] _GClosure* callback);

        // AstalIODaemon
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_io_daemon_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("guint")]
        public static partial uint astal_io_daemon_register_object([NativeTypeName("void *")] void* @object, [NativeTypeName("GDBusConnection *")] _GDBusConnection* connection, [NativeTypeName("const gchar *")] sbyte* path, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        public static partial void astal_io_daemon_request([NativeTypeName("AstalIODaemon *")] _AstalIODaemon* self, [NativeTypeName("const gchar *")] sbyte* request, [NativeTypeName("GSocketConnection *")] _GSocketConnection* conn, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIODaemon *")]
        public static partial _AstalIODaemon* astal_io_daemon_new();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIODaemon *")]
        public static partial _AstalIODaemon* astal_io_daemon_construct([NativeTypeName("GType")] nuint object_type);

        // AstalIOProcess
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_io_process_get_type();

        [LibraryImport(LibName)]
        public static partial void astal_io_process_kill([NativeTypeName("AstalIOProcess *")] _AstalIOProcess* self);

        [LibraryImport(LibName)]
        public static partial void astal_io_process_signal([NativeTypeName("AstalIOProcess *")] _AstalIOProcess* self, [NativeTypeName("gint")] int signal_num);

        [LibraryImport(LibName)]
        public static partial void astal_io_process_write([NativeTypeName("AstalIOProcess *")] _AstalIOProcess* self, [NativeTypeName("const gchar *")] sbyte* @in, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        public static partial void astal_io_process_write_async([NativeTypeName("AstalIOProcess *")] _AstalIOProcess* self, [NativeTypeName("const gchar *")] sbyte* @in, [NativeTypeName("GAsyncReadyCallback")] void* _callback_, [NativeTypeName("gpointer")] void* _user_data_);

        [LibraryImport(LibName)]
        public static partial void astal_io_process_write_finish([NativeTypeName("AstalIOProcess *")] _AstalIOProcess* self, [NativeTypeName("GAsyncResult *")] _GAsyncResult* _res_);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIOProcess *")]
        public static partial _AstalIOProcess* astal_io_process_new([NativeTypeName("gchar **")] sbyte** cmd, [NativeTypeName("gint")] int cmd_length1, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIOProcess *")]
        public static partial _AstalIOProcess* astal_io_process_construct([NativeTypeName("GType")] nuint object_type, [NativeTypeName("gchar **")] sbyte** cmd, [NativeTypeName("gint")] int cmd_length1, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIOProcess *")]
        public static partial _AstalIOProcess* astal_io_process_subprocessv([NativeTypeName("gchar **")] sbyte** cmd, [NativeTypeName("gint")] int cmd_length1, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIOProcess *")]
        public static partial _AstalIOProcess* astal_io_process_subprocess([NativeTypeName("const gchar *")] sbyte* cmd, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_io_process_execv([NativeTypeName("gchar **")] sbyte** cmd, [NativeTypeName("gint")] int cmd_length1, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_io_process_exec([NativeTypeName("const gchar *")] sbyte* cmd, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        public static partial void astal_io_process_exec_asyncv([NativeTypeName("gchar **")] sbyte** cmd, [NativeTypeName("gint")] int cmd_length1, [NativeTypeName("GAsyncReadyCallback")] void* _callback_, [NativeTypeName("gpointer")] void* _user_data_);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_io_process_exec_asyncv_finish([NativeTypeName("GAsyncResult *")] _GAsyncResult* _res_, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        public static partial void astal_io_process_exec_async([NativeTypeName("const gchar *")] sbyte* cmd, [NativeTypeName("GAsyncReadyCallback")] void* _callback_, [NativeTypeName("gpointer")] void* _user_data_);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_io_process_exec_finish([NativeTypeName("GAsyncResult *")] _GAsyncResult* _res_, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar **")]
        public static partial sbyte** astal_io_process_get_argv([NativeTypeName("AstalIOProcess *")] _AstalIOProcess* self, [NativeTypeName("gint *")] int* result_length1);

        // AstalIOTime
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_io_time_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIOTime *")]
        public static partial _AstalIOTime* astal_io_time_new_interval_prio([NativeTypeName("guint")] uint interval, [NativeTypeName("gint")] int prio, [NativeTypeName("GClosure *")] _GClosure* fn);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIOTime *")]
        public static partial _AstalIOTime* astal_io_time_construct_interval_prio([NativeTypeName("GType")] nuint object_type, [NativeTypeName("guint")] uint interval, [NativeTypeName("gint")] int prio, [NativeTypeName("GClosure *")] _GClosure* fn);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIOTime *")]
        public static partial _AstalIOTime* astal_io_time_new_timeout_prio([NativeTypeName("guint")] uint timeout, [NativeTypeName("gint")] int prio, [NativeTypeName("GClosure *")] _GClosure* fn);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIOTime *")]
        public static partial _AstalIOTime* astal_io_time_construct_timeout_prio([NativeTypeName("GType")] nuint object_type, [NativeTypeName("guint")] uint timeout, [NativeTypeName("gint")] int prio, [NativeTypeName("GClosure *")] _GClosure* fn);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIOTime *")]
        public static partial _AstalIOTime* astal_io_time_new_idle_prio([NativeTypeName("gint")] int prio, [NativeTypeName("GClosure *")] _GClosure* fn);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIOTime *")]
        public static partial _AstalIOTime* astal_io_time_construct_idle_prio([NativeTypeName("GType")] nuint object_type, [NativeTypeName("gint")] int prio, [NativeTypeName("GClosure *")] _GClosure* fn);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIOTime *")]
        public static partial _AstalIOTime* astal_io_time_interval([NativeTypeName("guint")] uint interval, [NativeTypeName("GClosure *")] _GClosure* fn);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIOTime *")]
        public static partial _AstalIOTime* astal_io_time_timeout([NativeTypeName("guint")] uint timeout, [NativeTypeName("GClosure *")] _GClosure* fn);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIOTime *")]
        public static partial _AstalIOTime* astal_io_time_idle([NativeTypeName("GClosure *")] _GClosure* fn);

        [LibraryImport(LibName)]
        public static partial void astal_io_time_cancel([NativeTypeName("AstalIOTime *")] _AstalIOTime* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIOTime *")]
        public static partial _AstalIOTime* astal_io_time_new();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIOTime *")]
        public static partial _AstalIOTime* astal_io_time_construct([NativeTypeName("GType")] nuint object_type);

        // AstalIOVariableBase
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_io_variable_base_get_type();

        [LibraryImport(LibName)]
        public static partial void astal_io_variable_base_emit_changed([NativeTypeName("AstalIOVariableBase *")] _AstalIOVariableBase* self);

        [LibraryImport(LibName)]
        public static partial void astal_io_variable_base_emit_dropped([NativeTypeName("AstalIOVariableBase *")] _AstalIOVariableBase* self);

        [LibraryImport(LibName)]
        public static partial void astal_io_variable_base_emit_error([NativeTypeName("AstalIOVariableBase *")] _AstalIOVariableBase* self, [NativeTypeName("const gchar *")] sbyte* err);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIOVariableBase *")]
        public static partial _AstalIOVariableBase* astal_io_variable_base_new();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIOVariableBase *")]
        public static partial _AstalIOVariableBase* astal_io_variable_base_construct([NativeTypeName("GType")] nuint object_type);

        // AstalIOVariable
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_io_variable_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIOVariable *")]
        public static partial _AstalIOVariable* astal_io_variable_new([NativeTypeName("GValue *")] _GValue* init);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIOVariable *")]
        public static partial _AstalIOVariable* astal_io_variable_construct([NativeTypeName("GType")] nuint object_type, [NativeTypeName("GValue *")] _GValue* init);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIOVariable *")]
        public static partial _AstalIOVariable* astal_io_variable_poll([NativeTypeName("AstalIOVariable *")] _AstalIOVariable* self, [NativeTypeName("guint")] uint interval, [NativeTypeName("const gchar *")] sbyte* exec, [NativeTypeName("GClosure *")] _GClosure* transform, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIOVariable *")]
        public static partial _AstalIOVariable* astal_io_variable_pollv([NativeTypeName("AstalIOVariable *")] _AstalIOVariable* self, [NativeTypeName("guint")] uint interval, [NativeTypeName("gchar **")] sbyte** execv, [NativeTypeName("gint")] int execv_length1, [NativeTypeName("GClosure *")] _GClosure* transform, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIOVariable *")]
        public static partial _AstalIOVariable* astal_io_variable_pollfn([NativeTypeName("AstalIOVariable *")] _AstalIOVariable* self, [NativeTypeName("guint")] uint interval, [NativeTypeName("GClosure *")] _GClosure* fn, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIOVariable *")]
        public static partial _AstalIOVariable* astal_io_variable_watch([NativeTypeName("AstalIOVariable *")] _AstalIOVariable* self, [NativeTypeName("const gchar *")] sbyte* exec, [NativeTypeName("GClosure *")] _GClosure* transform, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalIOVariable *")]
        public static partial _AstalIOVariable* astal_io_variable_watchv([NativeTypeName("AstalIOVariable *")] _AstalIOVariable* self, [NativeTypeName("gchar **")] sbyte** execv, [NativeTypeName("gint")] int execv_length1, [NativeTypeName("GClosure *")] _GClosure* transform, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        public static partial void astal_io_variable_start_poll([NativeTypeName("AstalIOVariable *")] _AstalIOVariable* self, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        public static partial void astal_io_variable_start_watch([NativeTypeName("AstalIOVariable *")] _AstalIOVariable* self, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        public static partial void astal_io_variable_stop_poll([NativeTypeName("AstalIOVariable *")] _AstalIOVariable* self);

        [LibraryImport(LibName)]
        public static partial void astal_io_variable_stop_watch([NativeTypeName("AstalIOVariable *")] _AstalIOVariable* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_io_variable_is_polling([NativeTypeName("AstalIOVariable *")] _AstalIOVariable* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_io_variable_is_watching([NativeTypeName("AstalIOVariable *")] _AstalIOVariable* self);

        [LibraryImport(LibName)]
        public static partial void astal_io_variable_get_value([NativeTypeName("AstalIOVariable *")] _AstalIOVariable* self, [NativeTypeName("GValue *")] _GValue* result);

        [LibraryImport(LibName)]
        public static partial void astal_io_variable_set_value([NativeTypeName("AstalIOVariable *")] _AstalIOVariable* self, [NativeTypeName("GValue *")] _GValue* value);
    }
}
