using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Aqueous.Bindings.AstalNotifd;
using Aqueous.Bindings.AstalNotifd.Services;
using Aqueous.Helpers;
using Gtk;

namespace Aqueous.Features.Notifications
{
    public class NotificationPopup
    {
        private readonly AstalApplication _app;
        private readonly List<PopupEntry> _activePopups = new();

        private class PopupEntry
        {
            public uint NotificationId;
            public AstalWindow Window = null!;
            public uint TimerId;
        }

        public NotificationPopup(AstalApplication app)
        {
            _app = app;
        }

        public void ShowNotification(AstalNotifdNotification notification)
        {
            GLib.Functions.IdleAdd(0, () =>
            {
                BuildPopup(notification);
                return false;
            });
        }

        public void RemovePopup(uint notificationId)
        {
            GLib.Functions.IdleAdd(0, () =>
            {
                var entry = _activePopups.Find(e => e.NotificationId == notificationId);
                if (entry != null)
                    ClosePopup(entry);
                return false;
            });
        }

        private unsafe void BuildPopup(AstalNotifdNotification notification)
        {
            var window = new AstalWindow();
            _app.GtkApplication.AddWindow(window.GtkWindow);
            window.Namespace = "notification-popup";
            window.Layer = AstalLayer.ASTAL_LAYER_OVERLAY;
            window.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_IGNORE;
            window.Keymode = AstalKeymode.ASTAL_KEYMODE_NONE;
            window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP
                          | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT;

            var container = Gtk.Box.New(Orientation.Vertical, 4);
            container.AddCssClass("notification-popup");

            // Urgency styling
            var urgency = notification.Urgency;
            if (urgency == AstalNotifdUrgency.Critical)
                container.AddCssClass("notification-critical");
            else if (urgency == AstalNotifdUrgency.Low)
                container.AddCssClass("notification-low");

            // Header row: app name + close button
            var header = Gtk.Box.New(Orientation.Horizontal, 8);
            header.AddCssClass("notification-popup-header");

            var appLabel = Gtk.Label.New(notification.AppName ?? "Unknown");
            appLabel.AddCssClass("notification-app-name");
            appLabel.Hexpand = true;
            appLabel.Halign = Align.Start;
            header.Append(appLabel);

            var closeBtn = Gtk.Button.New();
            closeBtn.AddCssClass("notification-close-btn");
            closeBtn.SetChild(Gtk.Label.New("✕"));
            var notifId = notification.Id;
            closeBtn.OnClicked += (_, _) =>
            {
                notification.Dismiss();
            };
            header.Append(closeBtn);
            container.Append(header);

            // Summary
            var summary = notification.Summary;
            if (!string.IsNullOrEmpty(summary))
            {
                var summaryLabel = Gtk.Label.New(summary);
                summaryLabel.AddCssClass("notification-summary");
                summaryLabel.Halign = Align.Start;
                summaryLabel.SetWrap(true);
                container.Append(summaryLabel);
            }

            // Body
            var body = notification.Body;
            if (!string.IsNullOrEmpty(body))
            {
                var bodyLabel = Gtk.Label.New(body);
                bodyLabel.AddCssClass("notification-body");
                bodyLabel.Halign = Align.Start;
                bodyLabel.SetWrap(true);
                container.Append(bodyLabel);
            }

            // Actions
            var actions = GetActions(notification);
            if (actions.Count > 0)
            {
                var actionBox = Gtk.Box.New(Orientation.Horizontal, 4);
                actionBox.AddCssClass("notification-actions");
                foreach (var action in actions)
                {
                    var btn = Gtk.Button.New();
                    btn.AddCssClass("notification-action-btn");
                    btn.SetChild(Gtk.Label.New(action.Label ?? action.Id ?? ""));
                    var actionId = action.Id;
                    btn.OnClicked += (_, _) =>
                    {
                        if (actionId != null)
                            notification.Invoke(actionId);
                    };
                    actionBox.Append(btn);
                }
                container.Append(actionBox);
            }

            window.GtkWindow.SetChild(container);
            window.GtkWindow.Present();

            var entry = new PopupEntry
            {
                NotificationId = notification.Id,
                Window = window
            };

            // Auto-dismiss after timeout (default 5s, critical stays longer)
            var timeout = notification.ExpireTimeout > 0
                ? (uint)notification.ExpireTimeout
                : (urgency == AstalNotifdUrgency.Critical ? 10000u : 5000u);

            entry.TimerId = GLib.Functions.TimeoutAdd(0, timeout, () =>
            {
                ClosePopup(entry);
                return false;
            });

            _activePopups.Add(entry);
        }

        private unsafe List<AstalNotifdAction> GetActions(AstalNotifdNotification notification)
        {
            var list = new List<AstalNotifdAction>();
            var glist = (IntPtr)AstalNotifdInterop.astal_notifd_notification_get_actions(notification.Handle);
            var current = glist;
            while (current != IntPtr.Zero)
            {
                var data = Marshal.ReadIntPtr(current, 0);
                if (data != IntPtr.Zero)
                    list.Add(new AstalNotifdAction((_AstalNotifdAction*)data));
                current = Marshal.ReadIntPtr(current, IntPtr.Size);
            }
            return list;
        }

        private void ClosePopup(PopupEntry entry)
        {
            if (entry.TimerId > 0)
                GLib.Functions.SourceRemove(entry.TimerId);
            AstalWindow? win = entry.Window;
            BackdropHelper.DestroyWindow(ref win);
            _activePopups.Remove(entry);
        }
    }
}
