using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalWirePlumber;

namespace Aqueous.Bindings.AstalWirePlumber.Services
{
    public unsafe class AstalWpProfile
    {
        private _AstalWpProfile* _handle;

        internal _AstalWpProfile* Handle => _handle;

        internal AstalWpProfile(_AstalWpProfile* handle)
        {
            _handle = handle;
        }

        public int Index => AstalWirePlumberInterop.astal_wp_profile_get_index(_handle);

        public string? Description => Marshal.PtrToStringAnsi((IntPtr)AstalWirePlumberInterop.astal_wp_profile_get_description(_handle));

        public string? Name => Marshal.PtrToStringAnsi((IntPtr)AstalWirePlumberInterop.astal_wp_profile_get_name(_handle));

        public AstalWpAvailable Available => (AstalWpAvailable)AstalWirePlumberInterop.astal_wp_profile_get_available(_handle);

        public int Priority => AstalWirePlumberInterop.astal_wp_profile_get_priority(_handle);
    }
}
