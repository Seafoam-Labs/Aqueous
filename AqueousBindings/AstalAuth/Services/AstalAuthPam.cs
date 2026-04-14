using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalAuth;

namespace Aqueous.Bindings.AstalAuth.Services
{
    public unsafe class AstalAuthPam
    {
        private _AstalAuthPam* _handle;
        private IntPtr _handlePtr;

        internal _AstalAuthPam* Handle => _handle;

        // Prevent GC of signal delegates
        private readonly List<Delegate> _pinnedDelegates = new();
        private readonly List<(IntPtr instance, ulong id)> _signalIds = new();

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate void VoidSignalHandler(IntPtr self, IntPtr userData);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate void StringSignalHandler(IntPtr self, IntPtr message, IntPtr userData);

        public event Action? OnSuccess;
        public event Action<string>? OnFail;
        public event Action<string>? OnAuthInfo;
        public event Action<string>? OnAuthError;

        internal AstalAuthPam(_AstalAuthPam* handle)
        {
            _handle = handle;
            _handlePtr = (IntPtr)handle;
        }

        public AstalAuthPam()
        {
            var gtype = AstalAuthInterop.astal_auth_pam_get_type();
            _handlePtr = AstalAuthInterop.g_object_new(gtype, IntPtr.Zero);
            _handle = (_AstalAuthPam*)_handlePtr;

            ConnectSignals();
        }

        private void ConnectSignals()
        {
            VoidSignalHandler successHandler = (self, userData) =>
            {
                OnSuccess?.Invoke();
            };
            _pinnedDelegates.Add(successHandler);
            _signalIds.Add((_handlePtr, ConnectSignal("success", successHandler)));

            StringSignalHandler failHandler = (self, message, userData) =>
            {
                var msg = Marshal.PtrToStringAnsi(message) ?? "";
                OnFail?.Invoke(msg);
            };
            _pinnedDelegates.Add(failHandler);
            _signalIds.Add((_handlePtr, ConnectSignal("fail", failHandler)));

            StringSignalHandler authInfoHandler = (self, message, userData) =>
            {
                var msg = Marshal.PtrToStringAnsi(message) ?? "";
                OnAuthInfo?.Invoke(msg);
            };
            _pinnedDelegates.Add(authInfoHandler);
            _signalIds.Add((_handlePtr, ConnectSignal("auth-info", authInfoHandler)));

            StringSignalHandler authErrorHandler = (self, message, userData) =>
            {
                var msg = Marshal.PtrToStringAnsi(message) ?? "";
                OnAuthError?.Invoke(msg);
            };
            _pinnedDelegates.Add(authErrorHandler);
            _signalIds.Add((_handlePtr, ConnectSignal("auth-error", authErrorHandler)));
        }

        private ulong ConnectSignal<TDelegate>(string signalName, TDelegate callback) where TDelegate : Delegate
        {
            var namePtr = Marshal.StringToHGlobalAnsi(signalName);
            try
            {
                return AstalAuthInterop.g_signal_connect_data(
                    _handlePtr, namePtr,
                    Marshal.GetFunctionPointerForDelegate(callback),
                    IntPtr.Zero, IntPtr.Zero, 0);
            }
            finally
            {
                Marshal.FreeHGlobal(namePtr);
            }
        }

        public string? Username
        {
            get => Marshal.PtrToStringAnsi((IntPtr)AstalAuthInterop.astal_auth_pam_get_username(_handle));
            set
            {
                var ptr = (sbyte*)Marshal.StringToHGlobalAnsi(value);
                try
                {
                    AstalAuthInterop.astal_auth_pam_set_username(_handle, ptr);
                }
                finally
                {
                    Marshal.FreeHGlobal((IntPtr)ptr);
                }
            }
        }

        public string? Service
        {
            get => Marshal.PtrToStringAnsi((IntPtr)AstalAuthInterop.astal_auth_pam_get_service(_handle));
            set
            {
                var ptr = (sbyte*)Marshal.StringToHGlobalAnsi(value);
                try
                {
                    AstalAuthInterop.astal_auth_pam_set_service(_handle, ptr);
                }
                finally
                {
                    Marshal.FreeHGlobal((IntPtr)ptr);
                }
            }
        }

        public bool StartAuthenticate() => AstalAuthInterop.astal_auth_pam_start_authenticate(_handle) != 0;

        public void SupplySecret(string secret)
        {
            var ptr = (sbyte*)Marshal.StringToHGlobalAnsi(secret);
            try
            {
                AstalAuthInterop.astal_auth_pam_supply_secret(_handle, ptr);
            }
            finally
            {
                Marshal.FreeHGlobal((IntPtr)ptr);
            }
        }

        public void Dispose()
        {
            foreach (var (instance, id) in _signalIds)
            {
                if (id > 0)
                    AstalAuthInterop.g_signal_handler_disconnect(instance, id);
            }
            _signalIds.Clear();
            _pinnedDelegates.Clear();
        }
    }
}
