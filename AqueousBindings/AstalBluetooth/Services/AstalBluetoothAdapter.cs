using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalBluetooth;
namespace Aqueous.Bindings.AstalBluetooth.Services
{
    public unsafe class AstalBluetoothAdapter
    {
        private _AstalBluetoothAdapter* _handle;
        internal _AstalBluetoothAdapter* Handle => _handle;
        internal AstalBluetoothAdapter(_AstalBluetoothAdapter* handle)
        {
            _handle = handle;
        }
        public string? ObjectPath => Marshal.PtrToStringAnsi((IntPtr)AstalBluetoothInterop.astal_bluetooth_adapter_get_object_path(_handle));
        public string? Address => Marshal.PtrToStringAnsi((IntPtr)AstalBluetoothInterop.astal_bluetooth_adapter_get_address(_handle));
        public string? Alias
        {
            get => Marshal.PtrToStringAnsi((IntPtr)AstalBluetoothInterop.astal_bluetooth_adapter_get_alias(_handle));
            set
            {
                var ptr = (sbyte*)Marshal.StringToHGlobalAnsi(value);
                try
                {
                    AstalBluetoothInterop.astal_bluetooth_adapter_set_alias(_handle, ptr);
                }
                finally
                {
                    Marshal.FreeHGlobal((IntPtr)ptr);
                }
            }
        }
        public bool Discoverable
        {
            get => AstalBluetoothInterop.astal_bluetooth_adapter_get_discoverable(_handle) != 0;
            set => AstalBluetoothInterop.astal_bluetooth_adapter_set_discoverable(_handle, value ? 1 : 0);
        }
        public bool Discovering => AstalBluetoothInterop.astal_bluetooth_adapter_get_discovering(_handle) != 0;
        public bool Pairable
        {
            get => AstalBluetoothInterop.astal_bluetooth_adapter_get_pairable(_handle) != 0;
            set => AstalBluetoothInterop.astal_bluetooth_adapter_set_pairable(_handle, value ? 1 : 0);
        }
        public bool Powered
        {
            get => AstalBluetoothInterop.astal_bluetooth_adapter_get_powered(_handle) != 0;
            set => AstalBluetoothInterop.astal_bluetooth_adapter_set_powered(_handle, value ? 1 : 0);
        }
        public string? Name => Marshal.PtrToStringAnsi((IntPtr)AstalBluetoothInterop.astal_bluetooth_adapter_get_name(_handle));
        public string? Modalias => Marshal.PtrToStringAnsi((IntPtr)AstalBluetoothInterop.astal_bluetooth_adapter_get_modalias(_handle));
        public uint Class => AstalBluetoothInterop.astal_bluetooth_adapter_get_class(_handle);
        public uint DiscoverableTimeout
        {
            get => AstalBluetoothInterop.astal_bluetooth_adapter_get_discoverable_timeout(_handle);
            set => AstalBluetoothInterop.astal_bluetooth_adapter_set_discoverable_timeout(_handle, value);
        }
        public uint PairableTimeout
        {
            get => AstalBluetoothInterop.astal_bluetooth_adapter_get_pairable_timeout(_handle);
            set => AstalBluetoothInterop.astal_bluetooth_adapter_set_pairable_timeout(_handle, value);
        }
        public IEnumerable<string> Uuids
        {
            get
            {
                var results = new List<string>();
                var arr = AstalBluetoothInterop.astal_bluetooth_adapter_get_uuids(_handle);
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
        public void StartDiscovery() => AstalBluetoothInterop.astal_bluetooth_adapter_start_discovery(_handle);
        public void StopDiscovery() => AstalBluetoothInterop.astal_bluetooth_adapter_stop_discovery(_handle);
        public void RemoveDevice(AstalBluetoothDevice device) => AstalBluetoothInterop.astal_bluetooth_adapter_remove_device(_handle, device.Handle);
    }
}
