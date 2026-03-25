using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalPowerProfiles;
namespace Aqueous.Bindings.AstalPowerProfiles.Services
{
    public unsafe class AstalPowerProfilesHold
    {
        private _AstalPowerProfilesHold* _handle;
        internal _AstalPowerProfilesHold* Handle => _handle;
        internal AstalPowerProfilesHold(_AstalPowerProfilesHold* handle)
        {
            _handle = handle;
        }
        public string? ApplicationId => Marshal.PtrToStringAnsi((IntPtr)_handle->application_id);
        public string? Profile => Marshal.PtrToStringAnsi((IntPtr)_handle->profile);
        public string? Reason => Marshal.PtrToStringAnsi((IntPtr)_handle->reason);
    }
}
