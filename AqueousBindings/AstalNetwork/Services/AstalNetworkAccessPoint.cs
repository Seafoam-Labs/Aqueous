using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalNetwork;
namespace Aqueous.Bindings.AstalNetwork.Services
{
    public unsafe class AstalNetworkAccessPoint
    {
        private _AstalNetworkAccessPoint* _handle;
        internal _AstalNetworkAccessPoint* Handle => _handle;
        internal AstalNetworkAccessPoint(_AstalNetworkAccessPoint* handle)
        {
            _handle = handle;
        }
        public string? Path => Marshal.PtrToStringAnsi((IntPtr)AstalNetworkInterop.astal_network_access_point_get_path(_handle));
        public uint Bandwidth => AstalNetworkInterop.astal_network_access_point_get_bandwidth(_handle);
        public string? Bssid => Marshal.PtrToStringAnsi((IntPtr)AstalNetworkInterop.astal_network_access_point_get_bssid(_handle));
        public uint Frequency => AstalNetworkInterop.astal_network_access_point_get_frequency(_handle);
        public int LastSeen => AstalNetworkInterop.astal_network_access_point_get_last_seen(_handle);
        public uint MaxBitrate => AstalNetworkInterop.astal_network_access_point_get_max_bitrate(_handle);
        public byte Strength => AstalNetworkInterop.astal_network_access_point_get_strength(_handle);
        public string? IconName => Marshal.PtrToStringAnsi((IntPtr)AstalNetworkInterop.astal_network_access_point_get_icon_name(_handle));
        public int Mode => AstalNetworkInterop.astal_network_access_point_get_mode(_handle);
        public int Flags => AstalNetworkInterop.astal_network_access_point_get_flags(_handle);
        public int RsnFlags => AstalNetworkInterop.astal_network_access_point_get_rsn_flags(_handle);
        public int WpaFlags => AstalNetworkInterop.astal_network_access_point_get_wpa_flags(_handle);
        public bool RequiresPassword => AstalNetworkInterop.astal_network_access_point_get_requires_password(_handle) != 0;
        public string? Ssid => Marshal.PtrToStringAnsi((IntPtr)AstalNetworkInterop.astal_network_access_point_get_ssid(_handle));
    }
}
