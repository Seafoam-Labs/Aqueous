using System.Linq;
using Aqueous.Features.Bar;
using Aqueous.Features.Bluetooth;
using Gtk;

namespace Aqueous.Widgets.BluetoothTray
{
    public class BluetoothTrayWidget
    {
        private readonly Gtk.Button _button;
        private readonly BarWindow? _barWindow;
        public Gtk.Button Button => _button;

        public BluetoothTrayWidget(BluetoothService service, BarWindow? barWindow = null)
        {
            _barWindow = barWindow;
            _button = Gtk.Button.New();
            _button.AddCssClass("bluetooth-tray-button");

            var label = Gtk.Label.New("󰂯");
            _button.SetChild(label);

            // Left-click: toggle popup
            _button.OnClicked += (_, _) =>
            {
                if (!service.IsPopupVisible)
                {
                    _barWindow?.PreventHide();
                }
                else
                {
                    _barWindow?.AllowHide();
                }
                service.Toggle(_button);
            };

            // Right-click: toggle adapter power
            var rightClick = Gtk.GestureClick.New();
            rightClick.SetButton(3);
            rightClick.OnReleased += (_, _) =>
            {
                _ = service.TogglePowerAsync();
            };
            _button.AddController(rightClick);

            service.StateChanged += () =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    UpdateIcon(label, service);
                    return false;
                });
            };

            // Allow hide when popup is closed externally
            service.PopupClosed += () =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    _barWindow?.AllowHide();
                    return false;
                });
            };

            UpdateIcon(label, service);
        }

        private static void UpdateIcon(Gtk.Label label, BluetoothService service)
        {
            if (!service.IsAdapterPowered)
            {
                label.SetText("󰂲"); // Bluetooth off
                label.RemoveCssClass("bt-connected");
                label.AddCssClass("bt-off");
            }
            else if (service.Devices.Any(d => d.IsConnected))
            {
                label.SetText("󰂱"); // Bluetooth connected
                label.RemoveCssClass("bt-off");
                label.AddCssClass("bt-connected");
            }
            else
            {
                label.SetText("󰂯"); // Bluetooth on
                label.RemoveCssClass("bt-off");
                label.RemoveCssClass("bt-connected");
            }
        }
    }
}
