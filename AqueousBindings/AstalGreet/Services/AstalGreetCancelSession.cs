using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalGreet;
namespace Aqueous.Bindings.AstalGreet.Services
{
    public unsafe class AstalGreetCancelSession
    {
        private _AstalGreetCancelSession* _handle;
        internal _AstalGreetCancelSession* Handle => _handle;
        internal AstalGreetCancelSession(_AstalGreetCancelSession* handle)
        {
            _handle = handle;
        }
        public AstalGreetCancelSession()
        {
            _handle = AstalGreetInterop.astal_greet_cancel_session_new();
        }
    }
}
