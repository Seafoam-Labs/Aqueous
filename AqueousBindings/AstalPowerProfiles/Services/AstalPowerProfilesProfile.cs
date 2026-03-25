using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalPowerProfiles;
namespace Aqueous.Bindings.AstalPowerProfiles.Services
{
    public unsafe class AstalPowerProfilesProfile
    {
        private _AstalPowerProfilesProfile* _handle;
        internal _AstalPowerProfilesProfile* Handle => _handle;
        internal AstalPowerProfilesProfile(_AstalPowerProfilesProfile* handle)
        {
            _handle = handle;
        }
        public string? ProfileName => Marshal.PtrToStringAnsi((IntPtr)_handle->profile);
        public string? CpuDriver => Marshal.PtrToStringAnsi((IntPtr)_handle->cpu_driver);
        public string? PlatformDriver => Marshal.PtrToStringAnsi((IntPtr)_handle->platform_driver);
        public string? Driver => Marshal.PtrToStringAnsi((IntPtr)_handle->driver);
    }
}
