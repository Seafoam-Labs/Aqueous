using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalNetwork;
namespace Aqueous.Bindings.AstalNetwork.Services
{
    public unsafe class AstalNetworkWired
    {
        private _AstalNetworkWired* _handle;
        internal _AstalNetworkWired* Handle => _handle;
        internal AstalNetworkWired(_AstalNetworkWired* handle)
        {
            _handle = handle;
        }
        public uint Speed => AstalNetworkInterop.astal_network_wired_get_speed(_handle);
        public AstalNetworkInternet Internet => (AstalNetworkInternet)AstalNetworkInterop.astal_network_wired_get_internet(_handle);
        public AstalNetworkDeviceState State => (AstalNetworkDeviceState)AstalNetworkInterop.astal_network_wired_get_state(_handle);
        public string? IconName => Marshal.PtrToStringAnsi((IntPtr)AstalNetworkInterop.astal_network_wired_get_icon_name(_handle));
    }
}
