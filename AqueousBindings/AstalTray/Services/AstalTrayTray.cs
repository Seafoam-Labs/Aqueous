using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalTray;

namespace Aqueous.Bindings.AstalTray.Services
{
    public unsafe class AstalTrayTray
    {
        private _AstalTrayTray* _handle;

        internal _AstalTrayTray* Handle => _handle;

        public AstalTrayTray()
        {
            _handle = AstalTrayInterop.astal_tray_tray_new();
        }

        internal AstalTrayTray(_AstalTrayTray* handle)
        {
            _handle = handle;
        }

        public static AstalTrayTray GetDefault()
        {
            return new AstalTrayTray(AstalTrayInterop.astal_tray_tray_get_default());
        }

        public AstalTrayTrayItem? GetItem(string itemId)
        {
            fixed (byte* ptr = System.Text.Encoding.UTF8.GetBytes(itemId + '\0'))
            {
                var result = AstalTrayInterop.astal_tray_tray_get_item(_handle, (sbyte*)ptr);
                return result == null ? null : new AstalTrayTrayItem(result);
            }
        }
    }
}
