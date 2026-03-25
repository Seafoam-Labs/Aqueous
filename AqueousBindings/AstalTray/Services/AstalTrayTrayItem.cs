using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalTray;

namespace Aqueous.Bindings.AstalTray.Services
{
    public unsafe class AstalTrayTrayItem
    {
        private _AstalTrayTrayItem* _handle;

        internal _AstalTrayTrayItem* Handle => _handle;

        internal AstalTrayTrayItem(_AstalTrayTrayItem* handle)
        {
            _handle = handle;
        }

        public void AboutToShow() => AstalTrayInterop.astal_tray_tray_item_about_to_show(_handle);

        public void Activate(int x, int y) => AstalTrayInterop.astal_tray_tray_item_activate(_handle, x, y);

        public void SecondaryActivate(int x, int y) => AstalTrayInterop.astal_tray_tray_item_secondary_activate(_handle, x, y);

        public void Scroll(int delta, string orientation)
        {
            fixed (byte* ptr = System.Text.Encoding.UTF8.GetBytes(orientation + '\0'))
                AstalTrayInterop.astal_tray_tray_item_scroll(_handle, delta, (sbyte*)ptr);
        }

        public string? ToJsonString() => Marshal.PtrToStringAnsi((IntPtr)AstalTrayInterop.astal_tray_tray_item_to_json_string(_handle));

        public string? Title => Marshal.PtrToStringAnsi((IntPtr)AstalTrayInterop.astal_tray_tray_item_get_title(_handle));

        public AstalTrayCategory Category => (AstalTrayCategory)AstalTrayInterop.astal_tray_tray_item_get_category(_handle);

        public AstalTrayStatus Status => (AstalTrayStatus)AstalTrayInterop.astal_tray_tray_item_get_status(_handle);

        public string? TooltipMarkup => Marshal.PtrToStringAnsi((IntPtr)AstalTrayInterop.astal_tray_tray_item_get_tooltip_markup(_handle));

        public string? TooltipText => Marshal.PtrToStringAnsi((IntPtr)AstalTrayInterop.astal_tray_tray_item_get_tooltip_text(_handle));

        public string? Id => Marshal.PtrToStringAnsi((IntPtr)AstalTrayInterop.astal_tray_tray_item_get_id(_handle));

        public bool IsMenu => AstalTrayInterop.astal_tray_tray_item_get_is_menu(_handle) != 0;

        public string? IconThemePath => Marshal.PtrToStringAnsi((IntPtr)AstalTrayInterop.astal_tray_tray_item_get_icon_theme_path(_handle));

        public string? IconName => Marshal.PtrToStringAnsi((IntPtr)AstalTrayInterop.astal_tray_tray_item_get_icon_name(_handle));

        public string? ItemId => Marshal.PtrToStringAnsi((IntPtr)AstalTrayInterop.astal_tray_tray_item_get_item_id(_handle));

        public string? MenuPath => Marshal.PtrToStringAnsi((IntPtr)AstalTrayInterop.astal_tray_tray_item_get_menu_path(_handle));
    }
}
