using Aqueous.Features.Bar;
using Aqueous.Features.Notifications;
using Gtk;

namespace Aqueous.Widgets.NotificationTray
{
    public class NotificationTrayWidget
    {
        private readonly Gtk.Button _button;
        private readonly BarWindow? _barWindow;

        public Gtk.Button Button => _button;

        public NotificationTrayWidget(NotificationService service, BarWindow? barWindow = null)
        {
            _barWindow = barWindow;
            _button = Gtk.Button.New();
            _button.AddCssClass("notification-tray-button");

            var label = Gtk.Label.New("󰂚");
            _button.SetChild(label);

            _button.OnClicked += (_, _) =>
            {
                if (!service.IsCenterVisible)
                {
                    _barWindow?.PreventHide();
                }
                else
                {
                    _barWindow?.AllowHide();
                }
                service.Toggle();
            };

            service.StateChanged += () =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    UpdateIcon(label, service);
                    return false;
                });
            };

            service.CenterClosed += () =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    _barWindow?.AllowHide();
                    return false;
                });
            };

            UpdateIcon(label, service);
        }

        private static void UpdateIcon(Gtk.Label label, NotificationService service)
        {
            var count = service.UnreadCount;
            if (count > 0)
            {
                label.SetText($"󰂚 {count}");
                label.RemoveCssClass("notification-none");
                label.AddCssClass("notification-unread");
            }
            else
            {
                label.SetText("󰂚");
                label.RemoveCssClass("notification-unread");
                label.AddCssClass("notification-none");
            }
        }
    }
}
