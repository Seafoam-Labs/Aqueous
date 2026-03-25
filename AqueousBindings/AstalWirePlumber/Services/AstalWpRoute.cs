using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalWirePlumber;

namespace Aqueous.Bindings.AstalWirePlumber.Services
{
    public unsafe class AstalWpRoute
    {
        private _AstalWpRoute* _handle;

        internal _AstalWpRoute* Handle => _handle;

        internal AstalWpRoute(_AstalWpRoute* handle)
        {
            _handle = handle;
        }

        public int Index => AstalWirePlumberInterop.astal_wp_route_get_index(_handle);

        public string? Description => Marshal.PtrToStringAnsi((IntPtr)AstalWirePlumberInterop.astal_wp_route_get_description(_handle));

        public string? Name => Marshal.PtrToStringAnsi((IntPtr)AstalWirePlumberInterop.astal_wp_route_get_name(_handle));

        public AstalWpDirection Direction => (AstalWpDirection)AstalWirePlumberInterop.astal_wp_route_get_direction(_handle);

        public AstalWpAvailable Available => (AstalWpAvailable)AstalWirePlumberInterop.astal_wp_route_get_available(_handle);

        public int Priority => AstalWirePlumberInterop.astal_wp_route_get_priority(_handle);

        public int Device => AstalWirePlumberInterop.astal_wp_route_get_device(_handle);
    }
}
