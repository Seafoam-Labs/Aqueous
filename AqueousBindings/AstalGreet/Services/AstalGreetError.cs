using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalGreet;
namespace Aqueous.Bindings.AstalGreet.Services
{
    public unsafe class AstalGreetError
    {
        private _AstalGreetError* _handle;
        internal _AstalGreetError* Handle => _handle;
        internal AstalGreetError(_AstalGreetError* handle)
        {
            _handle = handle;
        }
        public AstalGreetErrorType ErrorType
        {
            get => (AstalGreetErrorType)AstalGreetInterop.astal_greet_error_get_error_type(_handle);
        }
        public string? Description
        {
            get => Marshal.PtrToStringAnsi((IntPtr)AstalGreetInterop.astal_greet_error_get_description(_handle));
        }
    }
}
