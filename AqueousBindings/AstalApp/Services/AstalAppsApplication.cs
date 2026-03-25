using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalApp;
using Gio;

namespace Aqueous.Bindings.AstalApp.Services
{
    public unsafe class AstalAppsApplication
    {
        private _AstalAppsApplication* _handle;

        internal _AstalAppsApplication* Handle => _handle;

        internal AstalAppsApplication(_AstalAppsApplication* handle)
        {
            _handle = handle;
        }

        public string Name => Marshal.PtrToStringAnsi((IntPtr)AstalAppsInterop.astal_apps_application_get_name(_handle)) ?? string.Empty;
        public string Description => Marshal.PtrToStringAnsi((IntPtr)AstalAppsInterop.astal_apps_application_get_description(_handle)) ?? string.Empty;

        public GObject.Object? GDesktopAppInfo
        {
            get
            {
                var appPtr = AstalAppsInterop.astal_apps_application_get_app(_handle);
                return appPtr == null ? null : (GObject.Object)GObject.Internal.InstanceWrapper.WrapHandle<GObject.Object>((IntPtr)appPtr, false);
            }
            set
            {
                IntPtr appPtr = value?.Handle?.DangerousGetHandle() ?? IntPtr.Zero;
                AstalAppsInterop.astal_apps_application_set_app(_handle, (_GDesktopAppInfo*)appPtr);
            }
        }

        public string? Executable => Marshal.PtrToStringAnsi((IntPtr)AstalAppsInterop.astal_apps_application_get_executable(_handle));
        public string? IconName => Marshal.PtrToStringAnsi((IntPtr)AstalAppsInterop.astal_apps_application_get_icon_name(_handle));
        public string? WmClass => Marshal.PtrToStringAnsi((IntPtr)AstalAppsInterop.astal_apps_application_get_wm_class(_handle));
        public string? Entry => Marshal.PtrToStringAnsi((IntPtr)AstalAppsInterop.astal_apps_application_get_entry(_handle));

        public string? GetKey(string key)
        {
            var keyPtr = (sbyte*)Marshal.StringToHGlobalAnsi(key);
            try
            {
                return Marshal.PtrToStringAnsi((IntPtr)AstalAppsInterop.astal_apps_application_get_key(_handle, keyPtr));
            }
            finally
            {
                Marshal.FreeHGlobal((IntPtr)keyPtr);
            }
        }

        public int Frequency
        {
            get => AstalAppsInterop.astal_apps_application_get_frequency(_handle);
            set => AstalAppsInterop.astal_apps_application_set_frequency(_handle, value);
        }

        public bool Launch() => AstalAppsInterop.astal_apps_application_launch(_handle) != 0;

        public void FuzzyMatch(string query, out _AstalAppsScore score)
        {
            var queryPtr = (sbyte*)Marshal.StringToHGlobalAnsi(query);
            try
            {
                fixed (_AstalAppsScore* scorePtr = &score)
                {
                    AstalAppsInterop.astal_apps_application_fuzzy_match(_handle, queryPtr, scorePtr);
                }
            }
            finally
            {
                Marshal.FreeHGlobal((IntPtr)queryPtr);
            }
        }

        public void ExactMatch(string query, out _AstalAppsScore score)
        {
            var queryPtr = (sbyte*)Marshal.StringToHGlobalAnsi(query);
            try
            {
                fixed (_AstalAppsScore* scorePtr = &score)
                {
                    AstalAppsInterop.astal_apps_application_exact_match(_handle, queryPtr, scorePtr);
                }
            }
            finally
            {
                Marshal.FreeHGlobal((IntPtr)queryPtr);
            }
        }
    }
}
