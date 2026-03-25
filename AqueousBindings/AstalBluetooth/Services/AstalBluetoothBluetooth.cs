using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalBluetooth;
namespace Aqueous.Bindings.AstalBluetooth.Services
{
    public unsafe class AstalBluetoothBluetooth
    {
        private _AstalBluetoothBluetooth* _handle;
        internal _AstalBluetoothBluetooth* Handle => _handle;
        public AstalBluetoothBluetooth() : this(AstalBluetoothInterop.astal_bluetooth_bluetooth_new())
        {
        }
        internal AstalBluetoothBluetooth(_AstalBluetoothBluetooth* handle)
        {
            _handle = handle;
        }
        public static AstalBluetoothBluetooth? GetDefault()
        {
            var ptr = AstalBluetoothInterop.astal_bluetooth_bluetooth_get_default();
            return ptr == null ? null : new AstalBluetoothBluetooth(ptr);
        }
        public bool IsPowered => AstalBluetoothInterop.astal_bluetooth_bluetooth_get_is_powered(_handle) != 0;
        public bool IsConnected => AstalBluetoothInterop.astal_bluetooth_bluetooth_get_is_connected(_handle) != 0;
        public AstalBluetoothAdapter? Adapter
        {
            get
            {
                var ptr = AstalBluetoothInterop.astal_bluetooth_bluetooth_get_adapter(_handle);
                return ptr == null ? null : new AstalBluetoothAdapter(ptr);
            }
        }
        public IEnumerable<AstalBluetoothAdapter> Adapters
        {
            get
            {
                var listPtr = AstalBluetoothInterop.astal_bluetooth_bluetooth_get_adapters(_handle);
                return WrapGList<AstalBluetoothAdapter>(listPtr, p => new AstalBluetoothAdapter((_AstalBluetoothAdapter*)(void*)p));
            }
        }
        public IEnumerable<AstalBluetoothDevice> Devices
        {
            get
            {
                var listPtr = AstalBluetoothInterop.astal_bluetooth_bluetooth_get_devices(_handle);
                return WrapGList<AstalBluetoothDevice>(listPtr, p => new AstalBluetoothDevice((_AstalBluetoothDevice*)(void*)p));
            }
        }
        public void Toggle() => AstalBluetoothInterop.astal_bluetooth_bluetooth_toggle(_handle);
        private IEnumerable<T> WrapGList<T>(_GList* listPtr, Func<IntPtr, T> wrap)
        {
            var results = new List<T>();
            var current = listPtr;
            while (current != null)
            {
                void* data = *(void**)current;
                results.Add(wrap((IntPtr)data));
                current = *(_GList**)((byte*)current + sizeof(void*));
            }
            return results;
        }
    }
}
