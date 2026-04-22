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
    public class NotificationCenter
    {
        private readonly AstalApplication _app;
        private readonly NotificationBackend _backend;
        private AstalWindow? _window;
        private AstalWindow? _backdrop;
        private Gtk.Box? _listContainer;

        public bool IsVisible { get; private set; }
        public event Action? Closed;

        public NotificationCenter(AstalApplication app, NotificationBackend backend)
        {
            _app = app;
            _backend = backend;
        }

        public void Show(Gtk.Button? anchorButton = null)
        {
            if (IsVisible) return;
            IsVisible = true;

            GLib.Functions.IdleAdd(0, () =>
            {
                BuildWindow(anchorButton);
                return false;
            });
        }

        public void Hide()
        {
            if (!IsVisible || _window == null) return;

            BackdropHelper.DestroyBackdrop(ref _backdrop);
            BackdropHelper.DestroyWindow(ref _window);
            _listContainer = null;
            IsVisible = false;
            Closed?.Invoke();
        }

        public void Toggle(Gtk.Button? anchorButton = null)
        {
            if (IsVisible)
                Hide();
            else
                Show(anchorButton);
        }

        public void Refresh()
        {
            if (!IsVisible || _listContainer == null) return;

            GLib.Functions.IdleAdd(0, () =>
            {
                RebuildList();
                return false;
            });
        }

        private void BuildWindow(Gtk.Button? anchorButton)
        {
            _window = new AstalWindow();
            _app.GtkApplication.AddWindow(_window.GtkWindow);
            _window.Namespace = "notification-center";
            _window.Layer = AstalLayer.ASTAL_LAYER_OVERLAY;
            _window.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_IGNORE;
            // Pointer-only panel (list of cards). NONE prevents compositor swallowing the first click.
            _window.Keymode = AstalKeymode.ASTAL_KEYMODE_NONE;

            if (anchorButton != null)
            {
                var (x, y) = WidgetGeometryHelper.GetWidgetGlobalPos(anchorButton);
                var (screenWidth, screenHeight) = WidgetGeometryHelper.GetScreenSize();

                _window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_LEFT;
                _window.MarginLeft = x;
                _window.MarginTop = y + anchorButton.GetAllocatedHeight();

                if (_window.MarginLeft + 400 > screenWidth)
                    _window.MarginLeft = screenWidth - 405;
                if (_window.MarginTop + 500 > screenHeight)
                    _window.MarginTop = Math.Max(0, y - 505);
            }
            else
            {
                _window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP
                               | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT;
            }

            var mainContainer = Gtk.Box.New(Orientation.Vertical, 4);
            mainContainer.AddCssClass("notification-center");

            // Header
            var header = Gtk.Box.New(Orientation.Horizontal, 8);
            header.AddCssClass("notification-center-header");

            var title = Gtk.Label.New("Notifications");
            title.AddCssClass("section-header");
            title.Hexpand = true;
            title.Halign = Align.Start;
            header.Append(title);

            // DND toggle
            var dndSwitch = Gtk.Switch.New();
            dndSwitch.Active = _backend.DontDisturb;
            dndSwitch.Valign = Align.Center;
            dndSwitch.SetTooltipText("Do Not Disturb");
            dndSwitch.OnStateSet += (sender, args) =>
            {
                _backend.DontDisturb = args.State;
                return false;
            };
            header.Append(dndSwitch);

            // Clear all button
            var clearBtn = Gtk.Button.New();
            clearBtn.AddCssClass("notification-clear-btn");
            clearBtn.SetChild(Gtk.Label.New("Clear All"));
            clearBtn.OnClicked += (_, _) =>
            {
                DismissAll();
            };
            header.Append(clearBtn);
            mainContainer.Append(header);

            // Notification list
            _listContainer = Gtk.Box.New(Orientation.Vertical, 4);
            _listContainer.AddCssClass("notification-list");
            RebuildList();

            var scrolled = Gtk.ScrolledWindow.New();
            scrolled.SetPolicy(PolicyType.Never, PolicyType.Automatic);
            scrolled.SetMaxContentHeight(500);
            scrolled.SetPropagateNaturalHeight(true);
            scrolled.SetChild(_listContainer);
            mainContainer.Append(scrolled);

            // Escape key to dismiss
            var keyController = Gtk.EventControllerKey.New();
            keyController.OnKeyPressed += (controller, args) =>
            {
                if (args.Keyval == 0xff1b)
                {
                    Hide();
                    return true;
                }
                return false;
            };
            _window.GtkWindow.AddController(keyController);

            _backdrop = BackdropHelper.CreateBackdrop(_app, "notification-center-backdrop", AstalLayer.ASTAL_LAYER_OVERLAY, Hide);

            _window.GtkWindow.SetChild(mainContainer);
            _window.GtkWindow.Present();
        }

        private unsafe void RebuildList()
        {
            if (_listContainer == null) return;

            // Remove all children
            var child = _listContainer.GetFirstChild();
            while (child != null)
            {
                var next = child.GetNextSibling();
                _listContainer.Remove(child);
                child = next;
            }

            var notifications = _backend.GetNotifications();

            if (notifications.Count == 0)
            {
                Hide();
                return;
            }

            // Show newest first
            notifications.Reverse();

            foreach (var notification in notifications)
            {
                var row = Gtk.Box.New(Orientation.Vertical, 2);
                row.AddCssClass("notification-row");

                // Urgency styling
                var urgency = notification.Urgency;
                if (urgency == AstalNotifdUrgency.Critical)
                    row.AddCssClass("notification-critical");

                // Header: app name + time + close
                var rowHeader = Gtk.Box.New(Orientation.Horizontal, 8);
                rowHeader.AddCssClass("notification-row-header");

                var appLabel = Gtk.Label.New(notification.AppName ?? "Unknown");
                appLabel.AddCssClass("notification-app-name");
                appLabel.Hexpand = true;
                appLabel.Halign = Align.Start;
                rowHeader.Append(appLabel);

                var time = DateTimeOffset.FromUnixTimeSeconds(notification.Time).LocalDateTime;
                var timeStr = time.Date == DateTime.Today
                    ? time.ToString("h:mm tt")
                    : time.ToString("MMM d h:mm tt");
                var timeLabel = Gtk.Label.New(timeStr);
                timeLabel.AddCssClass("notification-time");
                rowHeader.Append(timeLabel);

                var dismissBtn = Gtk.Button.New();
                dismissBtn.AddCssClass("notification-dismiss-btn");
                dismissBtn.SetChild(Gtk.Label.New("✕"));
                dismissBtn.OnClicked += (_, _) =>
                {
                    notification.Dismiss();
                };
                rowHeader.Append(dismissBtn);
                row.Append(rowHeader);

                // Summary
                var summary = notification.Summary;
                if (!string.IsNullOrEmpty(summary))
                {
                    var summaryLabel = Gtk.Label.New(summary);
                    summaryLabel.AddCssClass("notification-summary");
                    summaryLabel.Halign = Align.Start;
                    summaryLabel.SetWrap(true);
                    row.Append(summaryLabel);
                }

                // Body
                var body = notification.Body;
                if (!string.IsNullOrEmpty(body))
                {
                    var bodyLabel = Gtk.Label.New(body);
                    bodyLabel.AddCssClass("notification-body");
                    bodyLabel.Halign = Align.Start;
                    bodyLabel.SetWrap(true);
                    row.Append(bodyLabel);
                }

                _listContainer.Append(row);
            }
        }

        private void DismissAll()
        {
            var notifications = _backend.GetNotifications();
            foreach (var n in notifications)
                n.Dismiss();
        }
    }
}
