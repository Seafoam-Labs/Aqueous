using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalIo;
namespace Aqueous.Bindings.AstalIo.Services
{
    public unsafe class AstalIoDaemon
    {
        private _AstalIODaemon* _handle;
        internal _AstalIODaemon* Handle => _handle;
        internal AstalIoDaemon(_AstalIODaemon* handle)
        {
            _handle = handle;
        }
        public static AstalIoDaemon? New()
        {
            var ptr = AstalIoInterop.astal_io_daemon_new();
            return ptr == null ? null : new AstalIoDaemon(ptr);
        }
        public void Request(string request, _GSocketConnection* conn)
        {
            var ptr = (sbyte*)Marshal.StringToHGlobalAnsi(request);
            try
            {
                _GError* error = null;
                AstalIoInterop.astal_io_daemon_request(_handle, ptr, conn, &error);
                if (error != null)
                    throw new Exception(Marshal.PtrToStringAnsi((IntPtr)error));
            }
            finally
            {
                Marshal.FreeHGlobal((IntPtr)ptr);
            }
        }
    }
}
