using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalBattery;

namespace Aqueous.Bindings.AstalBattery.Services
{
    public unsafe class AstalBatteryUPower
    {
        private _AstalBatteryUPower* _handle;

        internal _AstalBatteryUPower* Handle => _handle;

        public AstalBatteryUPower()
        {
            _handle = AstalBatteryInterop.astal_battery_upower_new();
        }

        internal AstalBatteryUPower(_AstalBatteryUPower* handle)
        {
            _handle = handle;
        }

        public AstalBatteryDevice? DisplayDevice
        {
            get
            {
                var ptr = AstalBatteryInterop.astal_battery_upower_get_display_device(_handle);
                return ptr == null ? null : new AstalBatteryDevice(ptr);
            }
        }

        public string? DaemonVersion => Marshal.PtrToStringAnsi((IntPtr)AstalBatteryInterop.astal_battery_upower_get_daemon_version(_handle));

        public bool OnBattery => AstalBatteryInterop.astal_battery_upower_get_on_battery(_handle) != 0;

        public bool LidIsClosed => AstalBatteryInterop.astal_battery_upower_get_lid_is_closed(_handle) != 0;

        public bool LidIsPresent => AstalBatteryInterop.astal_battery_upower_get_lid_is_present(_handle) != 0;

        public string? CriticalAction => Marshal.PtrToStringAnsi((IntPtr)AstalBatteryInterop.astal_battery_upower_get_critical_action(_handle));
    }
}
