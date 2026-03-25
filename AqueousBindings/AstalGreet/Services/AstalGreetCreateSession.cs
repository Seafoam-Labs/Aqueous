using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalGreet;
namespace Aqueous.Bindings.AstalGreet.Services
{
    public unsafe class AstalGreetCreateSession
    {
        private _AstalGreetCreateSession* _handle;
        internal _AstalGreetCreateSession* Handle => _handle;
        internal AstalGreetCreateSession(_AstalGreetCreateSession* handle)
        {
            _handle = handle;
        }
        public AstalGreetCreateSession(string username)
        {
            var ptr = (sbyte*)Marshal.StringToHGlobalAnsi(username);
            try
            {
                _handle = AstalGreetInterop.astal_greet_create_session_new(ptr);
            }
            finally
            {
                Marshal.FreeHGlobal((IntPtr)ptr);
            }
        }
        public string? Username
        {
            get => Marshal.PtrToStringAnsi((IntPtr)AstalGreetInterop.astal_greet_create_session_get_username(_handle));
            set
            {
                var ptr = (sbyte*)Marshal.StringToHGlobalAnsi(value);
                try
                {
                    AstalGreetInterop.astal_greet_create_session_set_username(_handle, ptr);
                }
                finally
                {
                    Marshal.FreeHGlobal((IntPtr)ptr);
                }
            }
        }
    }
}
