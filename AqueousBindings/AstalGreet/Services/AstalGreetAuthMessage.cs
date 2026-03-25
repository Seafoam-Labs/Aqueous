using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalGreet;
namespace Aqueous.Bindings.AstalGreet.Services
{
    public unsafe class AstalGreetAuthMessage
    {
        private _AstalGreetAuthMessage* _handle;
        internal _AstalGreetAuthMessage* Handle => _handle;
        internal AstalGreetAuthMessage(_AstalGreetAuthMessage* handle)
        {
            _handle = handle;
        }
        public AstalGreetAuthMessageType MessageType
        {
            get => (AstalGreetAuthMessageType)AstalGreetInterop.astal_greet_auth_message_get_message_type(_handle);
        }
        public string? Message
        {
            get => Marshal.PtrToStringAnsi((IntPtr)AstalGreetInterop.astal_greet_auth_message_get_message(_handle));
        }
    }
}
