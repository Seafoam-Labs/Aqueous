using System;
using System.Runtime.InteropServices;
namespace Aqueous.Bindings.AstalBluetooth
{
    public static unsafe partial class AstalBluetoothInterop
    {
        private const string LibName = "libastal-bluetooth.so";
        // AstalBluetoothAdapter
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_bluetooth_adapter_get_type();
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalBluetoothAdapter *")]
        public static partial _AstalBluetoothAdapter* astal_bluetooth_adapter_new([NativeTypeName("const char *")] sbyte* object_path);
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalBluetoothAdapter *")]
        public static partial _AstalBluetoothAdapter* astal_bluetooth_adapter_construct([NativeTypeName("GType")] nuint object_type, [NativeTypeName("const char *")] sbyte* object_path);
        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_bluetooth_adapter_get_object_path([NativeTypeName("AstalBluetoothAdapter *")] _AstalBluetoothAdapter* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_bluetooth_adapter_get_address([NativeTypeName("AstalBluetoothAdapter *")] _AstalBluetoothAdapter* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_bluetooth_adapter_get_alias([NativeTypeName("AstalBluetoothAdapter *")] _AstalBluetoothAdapter* self);
        [LibraryImport(LibName)]
        public static partial void astal_bluetooth_adapter_set_alias([NativeTypeName("AstalBluetoothAdapter *")] _AstalBluetoothAdapter* self, [NativeTypeName("const gchar *")] sbyte* value);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_bluetooth_adapter_get_discoverable([NativeTypeName("AstalBluetoothAdapter *")] _AstalBluetoothAdapter* self);
        [LibraryImport(LibName)]
        public static partial void astal_bluetooth_adapter_set_discoverable([NativeTypeName("AstalBluetoothAdapter *")] _AstalBluetoothAdapter* self, [NativeTypeName("gboolean")] int value);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_bluetooth_adapter_get_discovering([NativeTypeName("AstalBluetoothAdapter *")] _AstalBluetoothAdapter* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_bluetooth_adapter_get_pairable([NativeTypeName("AstalBluetoothAdapter *")] _AstalBluetoothAdapter* self);
        [LibraryImport(LibName)]
        public static partial void astal_bluetooth_adapter_set_pairable([NativeTypeName("AstalBluetoothAdapter *")] _AstalBluetoothAdapter* self, [NativeTypeName("gboolean")] int value);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_bluetooth_adapter_get_powered([NativeTypeName("AstalBluetoothAdapter *")] _AstalBluetoothAdapter* self);
        [LibraryImport(LibName)]
        public static partial void astal_bluetooth_adapter_set_powered([NativeTypeName("AstalBluetoothAdapter *")] _AstalBluetoothAdapter* self, [NativeTypeName("gboolean")] int value);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_bluetooth_adapter_get_name([NativeTypeName("AstalBluetoothAdapter *")] _AstalBluetoothAdapter* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_bluetooth_adapter_get_modalias([NativeTypeName("AstalBluetoothAdapter *")] _AstalBluetoothAdapter* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("guint")]
        public static partial uint astal_bluetooth_adapter_get_class([NativeTypeName("AstalBluetoothAdapter *")] _AstalBluetoothAdapter* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("guint")]
        public static partial uint astal_bluetooth_adapter_get_discoverable_timeout([NativeTypeName("AstalBluetoothAdapter *")] _AstalBluetoothAdapter* self);
        [LibraryImport(LibName)]
        public static partial void astal_bluetooth_adapter_set_discoverable_timeout([NativeTypeName("AstalBluetoothAdapter *")] _AstalBluetoothAdapter* self, [NativeTypeName("guint")] uint value);
        [LibraryImport(LibName)]
        [return: NativeTypeName("guint")]
        public static partial uint astal_bluetooth_adapter_get_pairable_timeout([NativeTypeName("AstalBluetoothAdapter *")] _AstalBluetoothAdapter* self);
        [LibraryImport(LibName)]
        public static partial void astal_bluetooth_adapter_set_pairable_timeout([NativeTypeName("AstalBluetoothAdapter *")] _AstalBluetoothAdapter* self, [NativeTypeName("guint")] uint value);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar **")]
        public static partial sbyte** astal_bluetooth_adapter_get_uuids([NativeTypeName("AstalBluetoothAdapter *")] _AstalBluetoothAdapter* self);
        [LibraryImport(LibName)]
        public static partial void astal_bluetooth_adapter_start_discovery([NativeTypeName("AstalBluetoothAdapter *")] _AstalBluetoothAdapter* self);
        [LibraryImport(LibName)]
        public static partial void astal_bluetooth_adapter_stop_discovery([NativeTypeName("AstalBluetoothAdapter *")] _AstalBluetoothAdapter* self);
        [LibraryImport(LibName)]
        public static partial void astal_bluetooth_adapter_remove_device([NativeTypeName("AstalBluetoothAdapter *")] _AstalBluetoothAdapter* self, [NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* device);
        // AstalBluetoothBattery
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_bluetooth_battery_get_type();
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalBluetoothBattery *")]
        public static partial _AstalBluetoothBattery* astal_bluetooth_battery_new([NativeTypeName("const char *")] sbyte* object_path);
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalBluetoothBattery *")]
        public static partial _AstalBluetoothBattery* astal_bluetooth_battery_construct([NativeTypeName("GType")] nuint object_type, [NativeTypeName("const char *")] sbyte* object_path);
        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_bluetooth_battery_get_object_path([NativeTypeName("AstalBluetoothBattery *")] _AstalBluetoothBattery* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_bluetooth_battery_get_percentage([NativeTypeName("AstalBluetoothBattery *")] _AstalBluetoothBattery* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_bluetooth_battery_get_source([NativeTypeName("AstalBluetoothBattery *")] _AstalBluetoothBattery* self);
        // AstalBluetoothBluetooth
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_bluetooth_bluetooth_get_type();
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalBluetoothBluetooth *")]
        public static partial _AstalBluetoothBluetooth* astal_bluetooth_bluetooth_new();
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalBluetoothBluetooth *")]
        public static partial _AstalBluetoothBluetooth* astal_bluetooth_bluetooth_construct([NativeTypeName("GType")] nuint object_type);
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalBluetoothBluetooth *")]
        public static partial _AstalBluetoothBluetooth* astal_bluetooth_bluetooth_get_default();
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalBluetoothBluetooth *")]
        public static partial _AstalBluetoothBluetooth* astal_bluetooth_get_default();
        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_bluetooth_bluetooth_get_is_powered([NativeTypeName("AstalBluetoothBluetooth *")] _AstalBluetoothBluetooth* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_bluetooth_bluetooth_get_is_connected([NativeTypeName("AstalBluetoothBluetooth *")] _AstalBluetoothBluetooth* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalBluetoothAdapter *")]
        public static partial _AstalBluetoothAdapter* astal_bluetooth_bluetooth_get_adapter([NativeTypeName("AstalBluetoothBluetooth *")] _AstalBluetoothBluetooth* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_bluetooth_bluetooth_get_adapters([NativeTypeName("AstalBluetoothBluetooth *")] _AstalBluetoothBluetooth* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_bluetooth_bluetooth_get_devices([NativeTypeName("AstalBluetoothBluetooth *")] _AstalBluetoothBluetooth* self);
        [LibraryImport(LibName)]
        public static partial void astal_bluetooth_bluetooth_toggle([NativeTypeName("AstalBluetoothBluetooth *")] _AstalBluetoothBluetooth* self);
        // AstalBluetoothDevice
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_bluetooth_device_get_type();
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalBluetoothDevice *")]
        public static partial _AstalBluetoothDevice* astal_bluetooth_device_new([NativeTypeName("const char *")] sbyte* object_path);
        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalBluetoothDevice *")]
        public static partial _AstalBluetoothDevice* astal_bluetooth_device_construct([NativeTypeName("GType")] nuint object_type, [NativeTypeName("const char *")] sbyte* object_path);
        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_bluetooth_device_get_object_path([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_bluetooth_device_get_connecting([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar **")]
        public static partial sbyte** astal_bluetooth_device_get_uuids([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_bluetooth_device_get_blocked([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self);
        [LibraryImport(LibName)]
        public static partial void astal_bluetooth_device_set_blocked([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self, [NativeTypeName("gboolean")] int value);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_bluetooth_device_get_connected([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_bluetooth_device_get_trusted([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self);
        [LibraryImport(LibName)]
        public static partial void astal_bluetooth_device_set_trusted([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self, [NativeTypeName("gboolean")] int value);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_bluetooth_device_get_paired([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_bluetooth_device_get_legacy_pairing([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gint16")]
        public static partial short astal_bluetooth_device_get_rssi([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_bluetooth_device_get_adapter([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_bluetooth_device_get_address([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_bluetooth_device_get_alias([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self);
        [LibraryImport(LibName)]
        public static partial void astal_bluetooth_device_set_alias([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self, [NativeTypeName("const gchar *")] sbyte* value);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_bluetooth_device_get_icon([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_bluetooth_device_get_modalias([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_bluetooth_device_get_name([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("guint16")]
        public static partial ushort astal_bluetooth_device_get_appearance([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("guint")]
        public static partial uint astal_bluetooth_device_get_class([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self);
        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_bluetooth_device_get_battery_percentage([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self);
        [LibraryImport(LibName)]
        public static partial void astal_bluetooth_device_set_battery([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self, [NativeTypeName("AstalBluetoothBattery *")] _AstalBluetoothBattery* value);
        [LibraryImport(LibName)]
        public static partial void astal_bluetooth_device_cancel_pairing([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self);
        [LibraryImport(LibName)]
        public static partial void astal_bluetooth_device_connect_device([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self, [NativeTypeName("GCancellable *")] _GCancellable* cancellable, [NativeTypeName("GAsyncReadyCallback")] delegate* unmanaged<_GObject*, _GAsyncResult*, void*, void> callback, [NativeTypeName("gpointer")] void* user_data);
        [LibraryImport(LibName)]
        public static partial void astal_bluetooth_device_connect_device_finish([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self, [NativeTypeName("GAsyncResult *")] _GAsyncResult* res, [NativeTypeName("GError **")] _GError** error);
        [LibraryImport(LibName)]
        public static partial void astal_bluetooth_device_connect_profile([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self, [NativeTypeName("const gchar *")] sbyte* uuid);
        [LibraryImport(LibName)]
        public static partial void astal_bluetooth_device_disconnect_device([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self, [NativeTypeName("GCancellable *")] _GCancellable* cancellable, [NativeTypeName("GAsyncReadyCallback")] delegate* unmanaged<_GObject*, _GAsyncResult*, void*, void> callback, [NativeTypeName("gpointer")] void* user_data);
        [LibraryImport(LibName)]
        public static partial void astal_bluetooth_device_disconnect_device_finish([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self, [NativeTypeName("GAsyncResult *")] _GAsyncResult* res, [NativeTypeName("GError **")] _GError** error);
        [LibraryImport(LibName)]
        public static partial void astal_bluetooth_device_disconnect_profile([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self, [NativeTypeName("const gchar *")] sbyte* uuid);
        [LibraryImport(LibName)]
        public static partial void astal_bluetooth_device_pair([NativeTypeName("AstalBluetoothDevice *")] _AstalBluetoothDevice* self);
        // Utility
        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_bluetooth_kebab_case([NativeTypeName("const gchar *")] sbyte* pascal);
    }
}
