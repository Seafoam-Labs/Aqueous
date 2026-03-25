using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalNetwork;
namespace Aqueous.Bindings.AstalNetwork.Services
{
    public unsafe class AstalNetworkWifi
    {
        private _AstalNetworkWifi* _handle;
        internal _AstalNetworkWifi* Handle => _handle;
        internal AstalNetworkWifi(_AstalNetworkWifi* handle)
        {
            _handle = handle;
        }
        public void Scan() => AstalNetworkInterop.astal_network_wifi_scan(_handle);
        public AstalNetworkAccessPoint? ActiveAccessPoint
        {
            get
            {
                var ptr = AstalNetworkInterop.astal_network_wifi_get_active_access_point(_handle);
                return ptr == null ? null : new AstalNetworkAccessPoint(ptr);
            }
        }
        public bool Enabled
        {
            get => AstalNetworkInterop.astal_network_wifi_get_enabled(_handle) != 0;
            set => AstalNetworkInterop.astal_network_wifi_set_enabled(_handle, value ? 1 : 0);
        }
        public AstalNetworkInternet Internet => (AstalNetworkInternet)AstalNetworkInterop.astal_network_wifi_get_internet(_handle);
        public uint Bandwidth => AstalNetworkInterop.astal_network_wifi_get_bandwidth(_handle);
        public string? Ssid => Marshal.PtrToStringAnsi((IntPtr)AstalNetworkInterop.astal_network_wifi_get_ssid(_handle));
        public byte Strength => AstalNetworkInterop.astal_network_wifi_get_strength(_handle);
        public uint Frequency => AstalNetworkInterop.astal_network_wifi_get_frequency(_handle);
        public AstalNetworkDeviceState State => (AstalNetworkDeviceState)AstalNetworkInterop.astal_network_wifi_get_state(_handle);
        public string? IconName => Marshal.PtrToStringAnsi((IntPtr)AstalNetworkInterop.astal_network_wifi_get_icon_name(_handle));
        public bool IsHotspot => AstalNetworkInterop.astal_network_wifi_get_is_hotspot(_handle) != 0;
        public bool Scanning => AstalNetworkInterop.astal_network_wifi_get_scanning(_handle) != 0;
    }
}
