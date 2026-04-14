extern alias AstalGreetAlias;

using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalGreet;
using Aqueous.Bindings.AstalGTK4.Services;

namespace AqueousGreeter
{
    public class GreeterService
    {
        private readonly AstalApplication _app;
        private GreeterWindow? _window;

        // prevent GC of the callback delegate
        private GAsyncReadyCallback? _loginCallback;

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private unsafe delegate void GAsyncReadyCallback(IntPtr source, IntPtr res, IntPtr userData);

        // GError layout: domain (uint32), code (int), message (IntPtr)
        [StructLayout(LayoutKind.Sequential)]
        private struct GErrorLayout
        {
            public uint domain;
            public int code;
            public IntPtr message;
        }

        public GreeterService(AstalApplication app)
        {
            _app = app;
        }

        public void Start()
        {
            _window = new GreeterWindow(_app);
            _window.OnLoginRequested += OnLoginRequested;
            _window.Show();
        }

        private unsafe void OnLoginRequested(string username, string password, string sessionCmd)
        {
            _window?.SetSensitive(false);
            _window?.SetStatus("Authenticating...", false);

            var usernamePtr = StringToSByte(username);
            var passwordPtr = StringToSByte(password);
            var cmdPtr = StringToSByte(sessionCmd);

            _loginCallback = (source, res, userData) =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    try
                    {
                        IntPtr errorPtr = IntPtr.Zero;
                        AstalGreetInterop.astal_greet_login_finish(
                            (AstalGreetAlias::_GAsyncResult*)res,
                            (AstalGreetAlias::_GError**)&errorPtr);
                        if (errorPtr != IntPtr.Zero)
                        {
                            var err = Marshal.PtrToStructure<GErrorLayout>(errorPtr);
                            var msg = Marshal.PtrToStringAnsi(err.message);
                            _window?.SetStatus(msg ?? "Login failed", true);
                            _window?.ClearPassword();
                            _window?.SetSensitive(true);
                        }
                        else
                        {
                            // Success — greetd will start the session, exit greeter
                            _app.GtkApplication.Quit();
                        }
                    }
                    finally
                    {
                        Marshal.FreeHGlobal((IntPtr)usernamePtr);
                        Marshal.FreeHGlobal((IntPtr)passwordPtr);
                        Marshal.FreeHGlobal((IntPtr)cmdPtr);
                    }
                    return false;
                });
            };

            var callbackPtr = Marshal.GetFunctionPointerForDelegate(_loginCallback);
            AstalGreetInterop.astal_greet_login(usernamePtr, passwordPtr, cmdPtr, callbackPtr, IntPtr.Zero);
        }

        private static unsafe sbyte* StringToSByte(string str)
        {
            var bytes = System.Text.Encoding.UTF8.GetBytes(str + '\0');
            var ptr = Marshal.AllocHGlobal(bytes.Length);
            Marshal.Copy(bytes, 0, ptr, bytes.Length);
            return (sbyte*)ptr;
        }
    }
}
