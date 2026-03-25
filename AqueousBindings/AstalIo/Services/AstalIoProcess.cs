using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalIo;
namespace Aqueous.Bindings.AstalIo.Services
{
    public unsafe class AstalIoProcess
    {
        private _AstalIOProcess* _handle;
        internal _AstalIOProcess* Handle => _handle;
        internal AstalIoProcess(_AstalIOProcess* handle)
        {
            _handle = handle;
        }
        public static AstalIoProcess? Subprocess(string cmd)
        {
            var cmdPtr = (sbyte*)Marshal.StringToHGlobalAnsi(cmd);
            try
            {
                _GError* error = null;
                var ptr = AstalIoInterop.astal_io_process_subprocess(cmdPtr, &error);
                if (error != null)
                    throw new Exception(Marshal.PtrToStringAnsi((IntPtr)error));
                return ptr == null ? null : new AstalIoProcess(ptr);
            }
            finally
            {
                Marshal.FreeHGlobal((IntPtr)cmdPtr);
            }
        }
        public static string? Exec(string cmd)
        {
            var cmdPtr = (sbyte*)Marshal.StringToHGlobalAnsi(cmd);
            try
            {
                _GError* error = null;
                var result = AstalIoInterop.astal_io_process_exec(cmdPtr, &error);
                if (error != null)
                    throw new Exception(Marshal.PtrToStringAnsi((IntPtr)error));
                return Marshal.PtrToStringAnsi((IntPtr)result);
            }
            finally
            {
                Marshal.FreeHGlobal((IntPtr)cmdPtr);
            }
        }
        public void Kill()
        {
            AstalIoInterop.astal_io_process_kill(_handle);
        }
        public void Signal(int signalNum)
        {
            AstalIoInterop.astal_io_process_signal(_handle, signalNum);
        }
        public void Write(string input)
        {
            var ptr = (sbyte*)Marshal.StringToHGlobalAnsi(input);
            try
            {
                _GError* error = null;
                AstalIoInterop.astal_io_process_write(_handle, ptr, &error);
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
