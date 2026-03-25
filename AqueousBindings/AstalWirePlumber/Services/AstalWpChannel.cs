using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalWirePlumber;

namespace Aqueous.Bindings.AstalWirePlumber.Services
{
    public unsafe class AstalWpChannel
    {
        private _AstalWpChannel* _handle;

        internal _AstalWpChannel* Handle => _handle;

        internal AstalWpChannel(_AstalWpChannel* handle)
        {
            _handle = handle;
        }

        public double Volume
        {
            get => AstalWirePlumberInterop.astal_wp_channel_get_volume(_handle);
            set => AstalWirePlumberInterop.astal_wp_channel_set_volume(_handle, value);
        }

        public string? Name => Marshal.PtrToStringAnsi((IntPtr)AstalWirePlumberInterop.astal_wp_channel_get_name(_handle));

        public string? VolumeIcon => Marshal.PtrToStringAnsi((IntPtr)AstalWirePlumberInterop.astal_wp_channel_get_volume_icon(_handle));
    }
}
