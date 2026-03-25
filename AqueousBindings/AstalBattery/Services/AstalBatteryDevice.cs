using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalBattery;

namespace Aqueous.Bindings.AstalBattery.Services
{
    public unsafe class AstalBatteryDevice
    {
        private _AstalBatteryDevice* _handle;

        internal _AstalBatteryDevice* Handle => _handle;

        internal AstalBatteryDevice(_AstalBatteryDevice* handle)
        {
            _handle = handle;
        }

        public static AstalBatteryDevice? GetDefault()
        {
            var ptr = AstalBatteryInterop.astal_battery_device_get_default();
            return ptr == null ? null : new AstalBatteryDevice(ptr);
        }

        public AstalBatteryType DeviceType => (AstalBatteryType)AstalBatteryInterop.astal_battery_device_get_device_type(_handle);

        public string? NativePath => Marshal.PtrToStringAnsi((IntPtr)AstalBatteryInterop.astal_battery_device_get_native_path(_handle));

        public string? Vendor => Marshal.PtrToStringAnsi((IntPtr)AstalBatteryInterop.astal_battery_device_get_vendor(_handle));

        public string? Model => Marshal.PtrToStringAnsi((IntPtr)AstalBatteryInterop.astal_battery_device_get_model(_handle));

        public string? Serial => Marshal.PtrToStringAnsi((IntPtr)AstalBatteryInterop.astal_battery_device_get_serial(_handle));

        public ulong UpdateTime => AstalBatteryInterop.astal_battery_device_get_update_time(_handle);

        public bool PowerSupply => AstalBatteryInterop.astal_battery_device_get_power_supply(_handle) != 0;

        public bool Online => AstalBatteryInterop.astal_battery_device_get_online(_handle) != 0;

        public double Energy => AstalBatteryInterop.astal_battery_device_get_energy(_handle);

        public double EnergyEmpty => AstalBatteryInterop.astal_battery_device_get_energy_empty(_handle);

        public double EnergyFull => AstalBatteryInterop.astal_battery_device_get_energy_full(_handle);

        public double EnergyFullDesign => AstalBatteryInterop.astal_battery_device_get_energy_full_design(_handle);

        public double EnergyRate => AstalBatteryInterop.astal_battery_device_get_energy_rate(_handle);

        public double Voltage => AstalBatteryInterop.astal_battery_device_get_voltage(_handle);

        public int ChargeCycles => AstalBatteryInterop.astal_battery_device_get_charge_cycles(_handle);

        public double Luminosity => AstalBatteryInterop.astal_battery_device_get_luminosity(_handle);

        public long TimeToEmpty => AstalBatteryInterop.astal_battery_device_get_time_to_empty(_handle);

        public long TimeToFull => AstalBatteryInterop.astal_battery_device_get_time_to_full(_handle);

        public double Percentage => AstalBatteryInterop.astal_battery_device_get_percentage(_handle);

        public double Temperature => AstalBatteryInterop.astal_battery_device_get_temperature(_handle);

        public bool IsPresent => AstalBatteryInterop.astal_battery_device_get_is_present(_handle) != 0;

        public AstalBatteryState State => (AstalBatteryState)AstalBatteryInterop.astal_battery_device_get_state(_handle);

        public bool IsRechargable => AstalBatteryInterop.astal_battery_device_get_is_rechargable(_handle) != 0;

        public double Capacity => AstalBatteryInterop.astal_battery_device_get_capacity(_handle);

        public AstalBatteryTechnology Technology => (AstalBatteryTechnology)AstalBatteryInterop.astal_battery_device_get_technology(_handle);

        public AstalBatteryWarningLevel WarningLevel => (AstalBatteryWarningLevel)AstalBatteryInterop.astal_battery_device_get_warning_level(_handle);

        public AstalBatteryBatteryLevel BatteryLevel => (AstalBatteryBatteryLevel)AstalBatteryInterop.astal_battery_device_get_battery_level(_handle);

        public string? IconName => Marshal.PtrToStringAnsi((IntPtr)AstalBatteryInterop.astal_battery_device_get_icon_name(_handle));

        public bool Charging => AstalBatteryInterop.astal_battery_device_get_charging(_handle) != 0;

        public bool IsBattery => AstalBatteryInterop.astal_battery_device_get_is_battery(_handle) != 0;

        public string? BatteryIconName => Marshal.PtrToStringAnsi((IntPtr)AstalBatteryInterop.astal_battery_device_get_battery_icon_name(_handle));

        public string? DeviceTypeName => Marshal.PtrToStringAnsi((IntPtr)AstalBatteryInterop.astal_battery_device_get_device_type_name(_handle));

        public string? DeviceTypeIcon => Marshal.PtrToStringAnsi((IntPtr)AstalBatteryInterop.astal_battery_device_get_device_type_icon(_handle));
    }
}
