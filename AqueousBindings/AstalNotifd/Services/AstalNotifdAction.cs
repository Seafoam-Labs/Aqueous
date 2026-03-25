using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalNotifd;

namespace Aqueous.Bindings.AstalNotifd.Services
{
    public unsafe class AstalNotifdAction
    {
        private _AstalNotifdAction* _handle;

        internal _AstalNotifdAction* Handle => _handle;

        public AstalNotifdAction(string id, string label)
        {
            fixed (byte* idPtr = System.Text.Encoding.UTF8.GetBytes(id + '\0'))
            fixed (byte* labelPtr = System.Text.Encoding.UTF8.GetBytes(label + '\0'))
            {
                _handle = AstalNotifdInterop.astal_notifd_action_new((sbyte*)idPtr, (sbyte*)labelPtr);
            }
        }

        internal AstalNotifdAction(_AstalNotifdAction* handle)
        {
            _handle = handle;
        }

        public void Invoke() => AstalNotifdInterop.astal_notifd_action_invoke(_handle);

        public string? Id
        {
            get => Marshal.PtrToStringAnsi((IntPtr)AstalNotifdInterop.astal_notifd_action_get_id(_handle));
            set
            {
                fixed (byte* ptr = System.Text.Encoding.UTF8.GetBytes((value ?? "") + '\0'))
                    AstalNotifdInterop.astal_notifd_action_set_id(_handle, (sbyte*)ptr);
            }
        }

        public string? Label
        {
            get => Marshal.PtrToStringAnsi((IntPtr)AstalNotifdInterop.astal_notifd_action_get_label(_handle));
            set
            {
                fixed (byte* ptr = System.Text.Encoding.UTF8.GetBytes((value ?? "") + '\0'))
                    AstalNotifdInterop.astal_notifd_action_set_label(_handle, (sbyte*)ptr);
            }
        }
    }
}
