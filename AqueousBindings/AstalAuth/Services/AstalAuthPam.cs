using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalAuth;

namespace Aqueous.Bindings.AstalAuth.Services
{
    public unsafe class AstalAuthPam
    {
        private _AstalAuthPam* _handle;

        internal _AstalAuthPam* Handle => _handle;

        internal AstalAuthPam(_AstalAuthPam* handle)
        {
            _handle = handle;
        }

        public string? Username
        {
            get => Marshal.PtrToStringAnsi((IntPtr)AstalAuthInterop.astal_auth_pam_get_username(_handle));
            set
            {
                var ptr = (sbyte*)Marshal.StringToHGlobalAnsi(value);
                try
                {
                    AstalAuthInterop.astal_auth_pam_set_username(_handle, ptr);
                }
                finally
                {
                    Marshal.FreeHGlobal((IntPtr)ptr);
                }
            }
        }

        public string? Service
        {
            get => Marshal.PtrToStringAnsi((IntPtr)AstalAuthInterop.astal_auth_pam_get_service(_handle));
            set
            {
                var ptr = (sbyte*)Marshal.StringToHGlobalAnsi(value);
                try
                {
                    AstalAuthInterop.astal_auth_pam_set_service(_handle, ptr);
                }
                finally
                {
                    Marshal.FreeHGlobal((IntPtr)ptr);
                }
            }
        }

        public bool StartAuthenticate() => AstalAuthInterop.astal_auth_pam_start_authenticate(_handle) != 0;

        public void SupplySecret(string secret)
        {
            var ptr = (sbyte*)Marshal.StringToHGlobalAnsi(secret);
            try
            {
                AstalAuthInterop.astal_auth_pam_supply_secret(_handle, ptr);
            }
            finally
            {
                Marshal.FreeHGlobal((IntPtr)ptr);
            }
        }
    }
}
