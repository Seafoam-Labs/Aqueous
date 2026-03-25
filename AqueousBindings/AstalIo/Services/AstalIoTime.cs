using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalIo;
namespace Aqueous.Bindings.AstalIo.Services
{
    public unsafe class AstalIoTime
    {
        private _AstalIOTime* _handle;
        internal _AstalIOTime* Handle => _handle;
        internal AstalIoTime(_AstalIOTime* handle)
        {
            _handle = handle;
        }
        public static AstalIoTime? Interval(uint interval, _GClosure* fn)
        {
            var ptr = AstalIoInterop.astal_io_time_interval(interval, fn);
            return ptr == null ? null : new AstalIoTime(ptr);
        }
        public static AstalIoTime? Timeout(uint timeout, _GClosure* fn)
        {
            var ptr = AstalIoInterop.astal_io_time_timeout(timeout, fn);
            return ptr == null ? null : new AstalIoTime(ptr);
        }
        public static AstalIoTime? Idle(_GClosure* fn)
        {
            var ptr = AstalIoInterop.astal_io_time_idle(fn);
            return ptr == null ? null : new AstalIoTime(ptr);
        }
        public void Cancel()
        {
            AstalIoInterop.astal_io_time_cancel(_handle);
        }
    }
}
