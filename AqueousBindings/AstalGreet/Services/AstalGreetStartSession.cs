using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalGreet;
namespace Aqueous.Bindings.AstalGreet.Services
{
    public unsafe class AstalGreetStartSession
    {
        private _AstalGreetStartSession* _handle;
        internal _AstalGreetStartSession* Handle => _handle;
        internal AstalGreetStartSession(_AstalGreetStartSession* handle)
        {
            _handle = handle;
        }
        public AstalGreetStartSession(string[] cmd, string[]? env = null)
        {
            var cmdBuf = (sbyte**)Marshal.AllocHGlobal(cmd.Length * sizeof(sbyte*));
            for (int i = 0; i < cmd.Length; i++)
                cmdBuf[i] = (sbyte*)Marshal.StringToHGlobalAnsi(cmd[i]);
            sbyte** envBuf = null;
            int envLen = 0;
            if (env != null)
            {
                envBuf = (sbyte**)Marshal.AllocHGlobal(env.Length * sizeof(sbyte*));
                envLen = env.Length;
                for (int i = 0; i < env.Length; i++)
                    envBuf[i] = (sbyte*)Marshal.StringToHGlobalAnsi(env[i]);
            }
            try
            {
                _handle = AstalGreetInterop.astal_greet_start_session_new(cmdBuf, cmd.Length, envBuf, envLen);
            }
            finally
            {
                for (int i = 0; i < cmd.Length; i++)
                    Marshal.FreeHGlobal((IntPtr)cmdBuf[i]);
                Marshal.FreeHGlobal((IntPtr)cmdBuf);
                if (env != null)
                {
                    for (int i = 0; i < env.Length; i++)
                        Marshal.FreeHGlobal((IntPtr)envBuf[i]);
                    Marshal.FreeHGlobal((IntPtr)envBuf);
                }
            }
        }
        public string[]? Cmd
        {
            get
            {
                int length;
                var ptrs = AstalGreetInterop.astal_greet_start_session_get_cmd(_handle, &length);
                if (ptrs == null) return null;
                var result = new string[length];
                for (int i = 0; i < length; i++)
                    result[i] = Marshal.PtrToStringAnsi((IntPtr)ptrs[i]) ?? string.Empty;
                return result;
            }
            set
            {
                if (value == null)
                {
                    AstalGreetInterop.astal_greet_start_session_set_cmd(_handle, null, 0);
                    return;
                }
                var ptrs = (sbyte**)Marshal.AllocHGlobal(value.Length * sizeof(sbyte*));
                for (int i = 0; i < value.Length; i++)
                    ptrs[i] = (sbyte*)Marshal.StringToHGlobalAnsi(value[i]);
                try
                {
                    AstalGreetInterop.astal_greet_start_session_set_cmd(_handle, ptrs, value.Length);
                }
                finally
                {
                    for (int i = 0; i < value.Length; i++)
                        Marshal.FreeHGlobal((IntPtr)ptrs[i]);
                    Marshal.FreeHGlobal((IntPtr)ptrs);
                }
            }
        }
        public string[]? Env
        {
            get
            {
                int length;
                var ptrs = AstalGreetInterop.astal_greet_start_session_get_env(_handle, &length);
                if (ptrs == null) return null;
                var result = new string[length];
                for (int i = 0; i < length; i++)
                    result[i] = Marshal.PtrToStringAnsi((IntPtr)ptrs[i]) ?? string.Empty;
                return result;
            }
            set
            {
                if (value == null)
                {
                    AstalGreetInterop.astal_greet_start_session_set_env(_handle, null, 0);
                    return;
                }
                var ptrs = (sbyte**)Marshal.AllocHGlobal(value.Length * sizeof(sbyte*));
                for (int i = 0; i < value.Length; i++)
                    ptrs[i] = (sbyte*)Marshal.StringToHGlobalAnsi(value[i]);
                try
                {
                    AstalGreetInterop.astal_greet_start_session_set_env(_handle, ptrs, value.Length);
                }
                finally
                {
                    for (int i = 0; i < value.Length; i++)
                        Marshal.FreeHGlobal((IntPtr)ptrs[i]);
                    Marshal.FreeHGlobal((IntPtr)ptrs);
                }
            }
        }
    }
}
