using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalGreet;
namespace Aqueous.Bindings.AstalGreet.Services
{
    public unsafe class AstalGreetPostAuthMesssage
    {
        private _AstalGreetPostAuthMesssage* _handle;
        internal _AstalGreetPostAuthMesssage* Handle => _handle;
        internal AstalGreetPostAuthMesssage(_AstalGreetPostAuthMesssage* handle)
        {
            _handle = handle;
        }
        public AstalGreetPostAuthMesssage(string response)
        {
            var ptr = (sbyte*)Marshal.StringToHGlobalAnsi(response);
            try
            {
                _handle = AstalGreetInterop.astal_greet_post_auth_messsage_new(ptr);
            }
            finally
            {
                Marshal.FreeHGlobal((IntPtr)ptr);
            }
        }
        public string? Response
        {
            get => Marshal.PtrToStringAnsi((IntPtr)AstalGreetInterop.astal_greet_post_auth_messsage_get_response(_handle));
            set
            {
                var ptr = (sbyte*)Marshal.StringToHGlobalAnsi(value);
                try
                {
                    AstalGreetInterop.astal_greet_post_auth_messsage_set_response(_handle, ptr);
                }
                finally
                {
                    Marshal.FreeHGlobal((IntPtr)ptr);
                }
            }
        }
    }
}
