using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalBluetooth;
namespace Aqueous.Bindings.AstalBluetooth.Services
{
    public unsafe class AstalBluetoothBattery
    {
        private _AstalBluetoothBattery* _handle;
        internal _AstalBluetoothBattery* Handle => _handle;
        internal AstalBluetoothBattery(_AstalBluetoothBattery* handle)
        {
            _handle = handle;
        }
        public string? ObjectPath => Marshal.PtrToStringAnsi((IntPtr)AstalBluetoothInterop.astal_bluetooth_battery_get_object_path(_handle));
        public double Percentage => AstalBluetoothInterop.astal_bluetooth_battery_get_percentage(_handle);
        public string? Source => Marshal.PtrToStringAnsi((IntPtr)AstalBluetoothInterop.astal_bluetooth_battery_get_source(_handle));
    }
}
