using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalNotifd;
using Aqueous.Bindings.AstalNotifd.Services;

namespace Aqueous.Features.Notifications
{
    public unsafe class NotificationBackend : IDisposable
    {
        private readonly AstalNotifdNotifd _notifd;
        private readonly List<ulong> _signalHandlerIds = new();

        public event Action<AstalNotifdNotification>? NotificationReceived;
        public event Action<uint, AstalNotifdClosedReason>? NotificationClosed;

        public bool DontDisturb
        {
            get => _notifd.DontDisturb;
            set => _notifd.DontDisturb = value;
        }

        public NotificationBackend()
        {
            _notifd = AstalNotifdNotifd.GetDefault();
            _notifd.IgnoreTimeout = true;

            ConnectSignals();
        }

        private void ConnectSignals()
        {
            _notifiedCallback = OnNotified;
            _resolvedCallback = OnResolved;

            var id1 = ConnectSignal((IntPtr)_notifd.Handle, "notified", _notifiedCallback);
            _signalHandlerIds.Add(id1);

            var id2 = ConnectSignal((IntPtr)_notifd.Handle, "resolved", _resolvedCallback);
            _signalHandlerIds.Add(id2);
        }

        // prevent GC of delegates
        private NotifiedCallback? _notifiedCallback;
        private ResolvedCallback? _resolvedCallback;

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate void NotifiedCallback(IntPtr self, uint id, int replaced, IntPtr userData);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate void ResolvedCallback(IntPtr self, uint id, int reason, IntPtr userData);

        private static ulong ConnectSignal<TDelegate>(IntPtr instance, string signalName, TDelegate callback) where TDelegate : Delegate
        {
            var namePtr = Marshal.StringToHGlobalAnsi(signalName);
            try
            {
                return g_signal_connect_data(
                    instance,
                    namePtr,
                    Marshal.GetFunctionPointerForDelegate<TDelegate>(callback),
                    IntPtr.Zero,
                    IntPtr.Zero,
                    0);
            }
            finally
            {
                Marshal.FreeHGlobal(namePtr);
            }
        }

        private void OnNotified(IntPtr self, uint id, int replaced, IntPtr userData)
        {
            var notification = _notifd.GetNotification(id);
            if (notification != null)
                NotificationReceived?.Invoke(notification);
        }

        private void OnResolved(IntPtr self, uint id, int reason, IntPtr userData)
        {
            NotificationClosed?.Invoke(id, (AstalNotifdClosedReason)reason);
        }

        public List<AstalNotifdNotification> GetNotifications()
        {
            var list = new List<AstalNotifdNotification>();
            var glist = (IntPtr)AstalNotifdInterop.astal_notifd_notifd_get_notifications(_notifd.Handle);
            var current = glist;
            while (current != IntPtr.Zero)
            {
                // GList: { gpointer data; GList *next; GList *prev; }
                var data = Marshal.ReadIntPtr(current, 0);
                if (data != IntPtr.Zero)
                    list.Add(new AstalNotifdNotification((_AstalNotifdNotification*)data));
                current = Marshal.ReadIntPtr(current, IntPtr.Size);
            }
            return list;
        }

        public void Dispose()
        {
            foreach (var id in _signalHandlerIds)
            {
                if (id > 0)
                    g_signal_handler_disconnect((IntPtr)_notifd.Handle, id);
            }
            _signalHandlerIds.Clear();
        }

        [DllImport("libgobject-2.0.so.0")]
        private static extern ulong g_signal_connect_data(
            IntPtr instance,
            IntPtr detailed_signal,
            IntPtr c_handler,
            IntPtr data,
            IntPtr destroy_data,
            int connect_flags);

        [DllImport("libgobject-2.0.so.0")]
        private static extern void g_signal_handler_disconnect(IntPtr instance, ulong handler_id);
    }
}
