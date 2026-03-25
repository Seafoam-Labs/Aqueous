using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalWirePlumber;

namespace Aqueous.Bindings.AstalWirePlumber.Services
{
    public unsafe class AstalWpDevice
    {
        private _AstalWpDevice* _handle;

        internal _AstalWpDevice* Handle => _handle;

        internal AstalWpDevice(_AstalWpDevice* handle)
        {
            _handle = handle;
        }

        public uint Id => AstalWirePlumberInterop.astal_wp_device_get_id(_handle);

        public string? Description => Marshal.PtrToStringAnsi((IntPtr)AstalWirePlumberInterop.astal_wp_device_get_description(_handle));

        public string? Icon => Marshal.PtrToStringAnsi((IntPtr)AstalWirePlumberInterop.astal_wp_device_get_icon(_handle));

        public AstalWpDeviceType DeviceType => (AstalWpDeviceType)AstalWirePlumberInterop.astal_wp_device_get_device_type(_handle);

        public string? FormFactor => Marshal.PtrToStringAnsi((IntPtr)AstalWirePlumberInterop.astal_wp_device_get_form_factor(_handle));

        public AstalWpProfile? GetProfile(int id)
        {
            var ptr = AstalWirePlumberInterop.astal_wp_device_get_profile(_handle, id);
            return ptr == null ? null : new AstalWpProfile(ptr);
        }

        public int ActiveProfileId
        {
            get => AstalWirePlumberInterop.astal_wp_device_get_active_profile_id(_handle);
            set => AstalWirePlumberInterop.astal_wp_device_set_active_profile_id(_handle, value);
        }

        public int InputRouteId => AstalWirePlumberInterop.astal_wp_device_get_input_route_id(_handle);

        public int OutputRouteId => AstalWirePlumberInterop.astal_wp_device_get_output_route_id(_handle);

        public AstalWpRoute? GetRoute(int id)
        {
            var ptr = AstalWirePlumberInterop.astal_wp_device_get_route(_handle, id);
            return ptr == null ? null : new AstalWpRoute(ptr);
        }

        public void SetRoute(AstalWpRoute route, uint cardDevice)
        {
            AstalWirePlumberInterop.astal_wp_device_set_route(_handle, route.Handle, cardDevice);
        }

        public string? GetPwProperty(string key)
        {
            fixed (byte* ptr = System.Text.Encoding.UTF8.GetBytes(key + '\0'))
                return Marshal.PtrToStringAnsi((IntPtr)AstalWirePlumberInterop.astal_wp_device_get_pw_property(_handle, (sbyte*)ptr));
        }
    }
}
