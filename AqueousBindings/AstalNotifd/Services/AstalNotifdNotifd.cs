using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalNotifd;

namespace Aqueous.Bindings.AstalNotifd.Services
{
    public unsafe class AstalNotifdNotifd
    {
        private _AstalNotifdNotifd* _handle;

        internal _AstalNotifdNotifd* Handle => _handle;

        public AstalNotifdNotifd()
        {
            _handle = AstalNotifdInterop.astal_notifd_notifd_new();
        }

        internal AstalNotifdNotifd(_AstalNotifdNotifd* handle)
        {
            _handle = handle;
        }

        public static AstalNotifdNotifd GetDefault()
        {
            return new AstalNotifdNotifd(AstalNotifdInterop.astal_notifd_notifd_get_default());
        }

        public AstalNotifdNotification? GetNotification(uint id)
        {
            var ptr = AstalNotifdInterop.astal_notifd_notifd_get_notification(_handle, id);
            return ptr == null ? null : new AstalNotifdNotification(ptr);
        }

        public bool IgnoreTimeout
        {
            get => AstalNotifdInterop.astal_notifd_notifd_get_ignore_timeout(_handle) != 0;
            set => AstalNotifdInterop.astal_notifd_notifd_set_ignore_timeout(_handle, value ? 1 : 0);
        }

        public bool DontDisturb
        {
            get => AstalNotifdInterop.astal_notifd_notifd_get_dont_disturb(_handle) != 0;
            set => AstalNotifdInterop.astal_notifd_notifd_set_dont_disturb(_handle, value ? 1 : 0);
        }

        public int DefaultTimeout
        {
            get => AstalNotifdInterop.astal_notifd_notifd_get_default_timeout(_handle);
            set => AstalNotifdInterop.astal_notifd_notifd_set_default_timeout(_handle, value);
        }
    }
}
