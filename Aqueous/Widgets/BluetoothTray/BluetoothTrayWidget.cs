using System.Linq;
using Aqueous.Features.Bluetooth;
using Gtk;

namespace Aqueous.Widgets.BluetoothTray
{
    public class BluetoothTrayWidget
    {
        private readonly Gtk.Button _button;
        public Gtk.Button Button => _button;

        public BluetoothTrayWidget(BluetoothService service)
        {
            _button = Gtk.Button.New();
            _button.AddCssClass("bluetooth-tray-button");

            var label = Gtk.Label.New("󰂯");
            _button.SetChild(label);

            _button.OnClicked += async (_, _) => await service.TogglePowerAsync();

            service.StateChanged += () =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    UpdateIcon(label, service);
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
