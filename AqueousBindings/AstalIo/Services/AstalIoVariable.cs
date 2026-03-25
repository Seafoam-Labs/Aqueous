using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalIo;
namespace Aqueous.Bindings.AstalIo.Services
{
    public unsafe class AstalIoVariable
    {
        private _AstalIOVariable* _handle;
        internal _AstalIOVariable* Handle => _handle;
        internal AstalIoVariable(_AstalIOVariable* handle)
        {
            _handle = handle;
        }
        public static AstalIoVariable? New(_GValue* init)
        {
            var ptr = AstalIoInterop.astal_io_variable_new(init);
            return ptr == null ? null : new AstalIoVariable(ptr);
        }
        public void StartPoll()
        {
            _GError* error = null;
            AstalIoInterop.astal_io_variable_start_poll(_handle, &error);
            if (error != null)
                throw new Exception(Marshal.PtrToStringAnsi((IntPtr)error));
        }
        public void StartWatch()
        {
            _GError* error = null;
            AstalIoInterop.astal_io_variable_start_watch(_handle, &error);
            if (error != null)
                throw new Exception(Marshal.PtrToStringAnsi((IntPtr)error));
        }
        public void StopPoll()
        {
            AstalIoInterop.astal_io_variable_stop_poll(_handle);
        }
        public void StopWatch()
        {
            AstalIoInterop.astal_io_variable_stop_watch(_handle);
        }
        public bool IsPolling => AstalIoInterop.astal_io_variable_is_polling(_handle) != 0;
        public bool IsWatching => AstalIoInterop.astal_io_variable_is_watching(_handle) != 0;
    }
}
