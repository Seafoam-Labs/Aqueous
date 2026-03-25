using System;
using System.Runtime.InteropServices;
namespace Aqueous.Bindings.AstalBattery
{
    public static unsafe partial class AstalBatteryInterop
    {
        private const string LibName = "libastal-battery.so";

        // AstalBatteryDevice
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_battery_device_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalBatteryDevice *")]
        public static partial _AstalBatteryDevice* astal_battery_get_default();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalBatteryDevice *")]
        public static partial _AstalBatteryDevice* astal_battery_device_get_default();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalBatteryDevice *")]
        public static partial _AstalBatteryDevice* astal_battery_device_new([NativeTypeName("const char *")] sbyte* path, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalBatteryDevice *")]
        public static partial _AstalBatteryDevice* astal_battery_device_construct([NativeTypeName("GType")] nuint object_type, [NativeTypeName("const char *")] sbyte* path, [NativeTypeName("GError **")] _GError** error);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalBatteryType")]
        public static partial int astal_battery_device_get_device_type([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_battery_device_get_native_path([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_battery_device_get_vendor([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_battery_device_get_model([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_battery_device_get_serial([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("guint64")]
        public static partial ulong astal_battery_device_get_update_time([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_battery_device_get_power_supply([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_battery_device_get_online([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_battery_device_get_energy([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_battery_device_get_energy_empty([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_battery_device_get_energy_full([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_battery_device_get_energy_full_design([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_battery_device_get_energy_rate([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_battery_device_get_voltage([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint")]
        public static partial int astal_battery_device_get_charge_cycles([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_battery_device_get_luminosity([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint64")]
        public static partial long astal_battery_device_get_time_to_empty([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gint64")]
        public static partial long astal_battery_device_get_time_to_full([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_battery_device_get_percentage([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_battery_device_get_temperature([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_battery_device_get_is_present([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalBatteryState")]
        public static partial int astal_battery_device_get_state([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_battery_device_get_is_rechargable([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gdouble")]
        public static partial double astal_battery_device_get_capacity([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalBatteryTechnology")]
        public static partial int astal_battery_device_get_technology([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalBatteryWarningLevel")]
        public static partial int astal_battery_device_get_warning_level([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalBatteryBatteryLevel")]
        public static partial int astal_battery_device_get_battery_level([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_battery_device_get_icon_name([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_battery_device_get_charging([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_battery_device_get_is_battery([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_battery_device_get_battery_icon_name([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_battery_device_get_device_type_name([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("const gchar *")]
        public static partial sbyte* astal_battery_device_get_device_type_icon([NativeTypeName("AstalBatteryDevice *")] _AstalBatteryDevice* self);

        // Enum GType getters
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_battery_type_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_battery_state_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_battery_technology_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_battery_warning_level_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_battery_battery_level_get_type();

        // AstalBatteryUPower
        [LibraryImport(LibName)]
        [return: NativeTypeName("GType")]
        public static partial nuint astal_battery_upower_get_type();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalBatteryUPower *")]
        public static partial _AstalBatteryUPower* astal_battery_upower_new();

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalBatteryUPower *")]
        public static partial _AstalBatteryUPower* astal_battery_upower_construct([NativeTypeName("GType")] nuint object_type);

        [LibraryImport(LibName)]
        [return: NativeTypeName("GList *")]
        public static partial _GList* astal_battery_upower_get_devices([NativeTypeName("AstalBatteryUPower *")] _AstalBatteryUPower* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("AstalBatteryDevice *")]
        public static partial _AstalBatteryDevice* astal_battery_upower_get_display_device([NativeTypeName("AstalBatteryUPower *")] _AstalBatteryUPower* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_battery_upower_get_daemon_version([NativeTypeName("AstalBatteryUPower *")] _AstalBatteryUPower* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_battery_upower_get_on_battery([NativeTypeName("AstalBatteryUPower *")] _AstalBatteryUPower* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_battery_upower_get_lid_is_closed([NativeTypeName("AstalBatteryUPower *")] _AstalBatteryUPower* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gboolean")]
        public static partial int astal_battery_upower_get_lid_is_present([NativeTypeName("AstalBatteryUPower *")] _AstalBatteryUPower* self);

        [LibraryImport(LibName)]
        [return: NativeTypeName("gchar *")]
        public static partial sbyte* astal_battery_upower_get_critical_action([NativeTypeName("AstalBatteryUPower *")] _AstalBatteryUPower* self);
    }
}
