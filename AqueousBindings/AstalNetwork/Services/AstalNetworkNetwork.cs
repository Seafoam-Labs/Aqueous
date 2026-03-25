using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalNetwork;
namespace Aqueous.Bindings.AstalNetwork.Services
{
    public unsafe class AstalNetworkNetwork
    {
        private _AstalNetworkNetwork* _handle;
        internal _AstalNetworkNetwork* Handle => _handle;
        internal AstalNetworkNetwork(_AstalNetworkNetwork* handle)
        {
            _handle = handle;
        }
        public AstalNetworkNetwork() : this(AstalNetworkInterop.astal_network_network_new())
        {
        }
        public static AstalNetworkNetwork? GetDefault()
        {
            var ptr = AstalNetworkInterop.astal_network_network_get_default();
            return ptr == null ? null : new AstalNetworkNetwork(ptr);
        }
        public AstalNetworkWifi? Wifi
        {
            get
            {
                var ptr = AstalNetworkInterop.astal_network_network_get_wifi(_handle);
                return ptr == null ? null : new AstalNetworkWifi(ptr);
            }
        }
        public AstalNetworkWired? Wired
        {
            get
            {
                var ptr = AstalNetworkInterop.astal_network_network_get_wired(_handle);
                return ptr == null ? null : new AstalNetworkWired(ptr);
            }
        }
        public AstalNetworkPrimary Primary => (AstalNetworkPrimary)AstalNetworkInterop.astal_network_network_get_primary(_handle);
        public AstalNetworkConnectivity Connectivity => (AstalNetworkConnectivity)AstalNetworkInterop.astal_network_network_get_connectivity(_handle);
        public AstalNetworkState State => (AstalNetworkState)AstalNetworkInterop.astal_network_network_get_state(_handle);
    }
}
