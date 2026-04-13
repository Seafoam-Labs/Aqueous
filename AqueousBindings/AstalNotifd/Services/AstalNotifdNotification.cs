using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalNotifd;

namespace Aqueous.Bindings.AstalNotifd.Services
{
    public unsafe class AstalNotifdNotification
    {
        private _AstalNotifdNotification* _handle;

        public _AstalNotifdNotification* Handle => _handle;

        public AstalNotifdNotification()
        {
            _handle = AstalNotifdInterop.astal_notifd_notification_new();
        }

        public AstalNotifdNotification(_AstalNotifdNotification* handle)
        {
            _handle = handle;
        }

        public void Dismiss() => AstalNotifdInterop.astal_notifd_notification_dismiss(_handle);

        public void Expire() => AstalNotifdInterop.astal_notifd_notification_expire(_handle);

        public void Invoke(string actionId)
        {
            fixed (byte* ptr = System.Text.Encoding.UTF8.GetBytes(actionId + '\0'))
                AstalNotifdInterop.astal_notifd_notification_invoke(_handle, (sbyte*)ptr);
        }

        public AstalNotifdNotification AddAction(AstalNotifdAction action)
        {
            var result = AstalNotifdInterop.astal_notifd_notification_add_action(_handle, action.Handle);
            return new AstalNotifdNotification(result);
        }

        public AstalNotifdState State => (AstalNotifdState)AstalNotifdInterop.astal_notifd_notification_get_state(_handle);

        public long Time => AstalNotifdInterop.astal_notifd_notification_get_time(_handle);

        public uint Id
        {
            get => AstalNotifdInterop.astal_notifd_notification_get_id(_handle);
            set => AstalNotifdInterop.astal_notifd_notification_set_id(_handle, value);
        }

        public string? AppName
        {
            get => Marshal.PtrToStringAnsi((IntPtr)AstalNotifdInterop.astal_notifd_notification_get_app_name(_handle));
            set
            {
                fixed (byte* ptr = System.Text.Encoding.UTF8.GetBytes((value ?? "") + '\0'))
                    AstalNotifdInterop.astal_notifd_notification_set_app_name(_handle, (sbyte*)ptr);
            }
        }

        public string? AppIcon
        {
            get => Marshal.PtrToStringAnsi((IntPtr)AstalNotifdInterop.astal_notifd_notification_get_app_icon(_handle));
            set
            {
                fixed (byte* ptr = System.Text.Encoding.UTF8.GetBytes((value ?? "") + '\0'))
                    AstalNotifdInterop.astal_notifd_notification_set_app_icon(_handle, (sbyte*)ptr);
            }
        }

        public string? Summary
        {
            get => Marshal.PtrToStringAnsi((IntPtr)AstalNotifdInterop.astal_notifd_notification_get_summary(_handle));
            set
            {
                fixed (byte* ptr = System.Text.Encoding.UTF8.GetBytes((value ?? "") + '\0'))
                    AstalNotifdInterop.astal_notifd_notification_set_summary(_handle, (sbyte*)ptr);
            }
        }

        public string? Body
        {
            get => Marshal.PtrToStringAnsi((IntPtr)AstalNotifdInterop.astal_notifd_notification_get_body(_handle));
            set
            {
                fixed (byte* ptr = System.Text.Encoding.UTF8.GetBytes((value ?? "") + '\0'))
                    AstalNotifdInterop.astal_notifd_notification_set_body(_handle, (sbyte*)ptr);
            }
        }

        public int ExpireTimeout
        {
            get => AstalNotifdInterop.astal_notifd_notification_get_expire_timeout(_handle);
            set => AstalNotifdInterop.astal_notifd_notification_set_expire_timeout(_handle, value);
        }

        public string? Image
        {
            get => Marshal.PtrToStringAnsi((IntPtr)AstalNotifdInterop.astal_notifd_notification_get_image(_handle));
            set
            {
                fixed (byte* ptr = System.Text.Encoding.UTF8.GetBytes((value ?? "") + '\0'))
                    AstalNotifdInterop.astal_notifd_notification_set_image(_handle, (sbyte*)ptr);
            }
        }

        public bool ActionIcons
        {
            get => AstalNotifdInterop.astal_notifd_notification_get_action_icons(_handle) != 0;
            set => AstalNotifdInterop.astal_notifd_notification_set_action_icons(_handle, value ? 1 : 0);
        }

        public string? Category
        {
            get => Marshal.PtrToStringAnsi((IntPtr)AstalNotifdInterop.astal_notifd_notification_get_category(_handle));
            set
            {
                fixed (byte* ptr = System.Text.Encoding.UTF8.GetBytes((value ?? "") + '\0'))
                    AstalNotifdInterop.astal_notifd_notification_set_category(_handle, (sbyte*)ptr);
            }
        }

        public string? DesktopEntry
        {
            get => Marshal.PtrToStringAnsi((IntPtr)AstalNotifdInterop.astal_notifd_notification_get_desktop_entry(_handle));
            set
            {
                fixed (byte* ptr = System.Text.Encoding.UTF8.GetBytes((value ?? "") + '\0'))
                    AstalNotifdInterop.astal_notifd_notification_set_desktop_entry(_handle, (sbyte*)ptr);
            }
        }

        public bool Resident
        {
            get => AstalNotifdInterop.astal_notifd_notification_get_resident(_handle) != 0;
            set => AstalNotifdInterop.astal_notifd_notification_set_resident(_handle, value ? 1 : 0);
        }

        public string? SoundFile
        {
            get => Marshal.PtrToStringAnsi((IntPtr)AstalNotifdInterop.astal_notifd_notification_get_sound_file(_handle));
            set
            {
                fixed (byte* ptr = System.Text.Encoding.UTF8.GetBytes((value ?? "") + '\0'))
                    AstalNotifdInterop.astal_notifd_notification_set_sound_file(_handle, (sbyte*)ptr);
            }
        }

        public string? SoundName
        {
            get => Marshal.PtrToStringAnsi((IntPtr)AstalNotifdInterop.astal_notifd_notification_get_sound_name(_handle));
            set
            {
                fixed (byte* ptr = System.Text.Encoding.UTF8.GetBytes((value ?? "") + '\0'))
                    AstalNotifdInterop.astal_notifd_notification_set_sound_name(_handle, (sbyte*)ptr);
            }
        }

        public bool SuppressSound
        {
            get => AstalNotifdInterop.astal_notifd_notification_get_suppress_sound(_handle) != 0;
            set => AstalNotifdInterop.astal_notifd_notification_set_suppress_sound(_handle, value ? 1 : 0);
        }

        public bool Transient
        {
            get => AstalNotifdInterop.astal_notifd_notification_get_transient(_handle) != 0;
            set => AstalNotifdInterop.astal_notifd_notification_set_transient(_handle, value ? 1 : 0);
        }

        public int X
        {
            get => AstalNotifdInterop.astal_notifd_notification_get_x(_handle);
            set => AstalNotifdInterop.astal_notifd_notification_set_x(_handle, value);
        }

        public int Y
        {
            get => AstalNotifdInterop.astal_notifd_notification_get_y(_handle);
            set => AstalNotifdInterop.astal_notifd_notification_set_y(_handle, value);
        }

        public AstalNotifdUrgency Urgency
        {
            get => (AstalNotifdUrgency)AstalNotifdInterop.astal_notifd_notification_get_urgency(_handle);
            set => AstalNotifdInterop.astal_notifd_notification_set_urgency(_handle, (int)value);
        }
    }
}
