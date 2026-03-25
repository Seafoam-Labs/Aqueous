using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalBluetooth;
namespace Aqueous.Bindings.AstalBluetooth.Services
{
    public unsafe class AstalBluetoothDevice
    {
        private _AstalBluetoothDevice* _handle;
        internal _AstalBluetoothDevice* Handle => _handle;
        internal AstalBluetoothDevice(_AstalBluetoothDevice* handle)
        {
            _handle = handle;
        }
        public string? ObjectPath => Marshal.PtrToStringAnsi((IntPtr)AstalBluetoothInterop.astal_bluetooth_device_get_object_path(_handle));
        public bool Connecting => AstalBluetoothInterop.astal_bluetooth_device_get_connecting(_handle) != 0;
        public IEnumerable<string> Uuids
        {
            get
            {
                var results = new List<string>();
                var arr = AstalBluetoothInterop.astal_bluetooth_device_get_uuids(_handle);
                if (arr != null)
                {
                    for (int i = 0; arr[i] != null; i++)
                    {
                        var s = Marshal.PtrToStringAnsi((IntPtr)arr[i]);
                        if (s != null) results.Add(s);
                    }
                }
                return results;
            }
        }
        public bool Blocked
        {
            get => AstalBluetoothInterop.astal_bluetooth_device_get_blocked(_handle) != 0;
            set => AstalBluetoothInterop.astal_bluetooth_device_set_blocked(_handle, value ? 1 : 0);
        }
        public bool Connected => AstalBluetoothInterop.astal_bluetooth_device_get_connected(_handle) != 0;
        public bool Trusted
        {
            get => AstalBluetoothInterop.astal_bluetooth_device_get_trusted(_handle) != 0;
            set => AstalBluetoothInterop.astal_bluetooth_device_set_trusted(_handle, value ? 1 : 0);
        }
        public bool Paired => AstalBluetoothInterop.astal_bluetooth_device_get_paired(_handle) != 0;
        public bool LegacyPairing => AstalBluetoothInterop.astal_bluetooth_device_get_legacy_pairing(_handle) != 0;
        public short Rssi => AstalBluetoothInterop.astal_bluetooth_device_get_rssi(_handle);
        public string? Adapter => Marshal.PtrToStringAnsi((IntPtr)AstalBluetoothInterop.astal_bluetooth_device_get_adapter(_handle));
        public string? Address => Marshal.PtrToStringAnsi((IntPtr)AstalBluetoothInterop.astal_bluetooth_device_get_address(_handle));
        public string? Alias
        {
            get => Marshal.PtrToStringAnsi((IntPtr)AstalBluetoothInterop.astal_bluetooth_device_get_alias(_handle));
            set
            {
                var ptr = (sbyte*)Marshal.StringToHGlobalAnsi(value);
                try
                {
                    AstalBluetoothInterop.astal_bluetooth_device_set_alias(_handle, ptr);
                }
                finally
                {
                    Marshal.FreeHGlobal((IntPtr)ptr);
                }
            }
        }
        public string? Icon => Marshal.PtrToStringAnsi((IntPtr)AstalBluetoothInterop.astal_bluetooth_device_get_icon(_handle));
        public string? Modalias => Marshal.PtrToStringAnsi((IntPtr)AstalBluetoothInterop.astal_bluetooth_device_get_modalias(_handle));
        public string? Name => Marshal.PtrToStringAnsi((IntPtr)AstalBluetoothInterop.astal_bluetooth_device_get_name(_handle));
        public ushort Appearance => AstalBluetoothInterop.astal_bluetooth_device_get_appearance(_handle);
        public uint Class => AstalBluetoothInterop.astal_bluetooth_device_get_class(_handle);
        public double BatteryPercentage => AstalBluetoothInterop.astal_bluetooth_device_get_battery_percentage(_handle);
        public void CancelPairing() => AstalBluetoothInterop.astal_bluetooth_device_cancel_pairing(_handle);
        public void ConnectProfile(string uuid)
        {
            var ptr = (sbyte*)Marshal.StringToHGlobalAnsi(uuid);
            try
            {
                AstalBluetoothInterop.astal_bluetooth_device_connect_profile(_handle, ptr);
            }
            finally
            {
                Marshal.FreeHGlobal((IntPtr)ptr);
            }
        }
        public void DisconnectProfile(string uuid)
        {
            var ptr = (sbyte*)Marshal.StringToHGlobalAnsi(uuid);
            try
            {
                AstalBluetoothInterop.astal_bluetooth_device_disconnect_profile(_handle, ptr);
            }
            finally
            {
                Marshal.FreeHGlobal((IntPtr)ptr);
            }
        }
        public void Pair() => AstalBluetoothInterop.astal_bluetooth_device_pair(_handle);
    }
}
