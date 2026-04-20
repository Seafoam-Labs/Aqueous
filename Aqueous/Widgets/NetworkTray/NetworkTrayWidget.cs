using System.Linq;
using Aqueous.Features.Bar;
using Aqueous.Features.Network;
using Gtk;

namespace Aqueous.Widgets.NetworkTray
{
    public class NetworkTrayWidget
    {
        private readonly Gtk.Button _button;
        private readonly BarWindow? _barWindow;
        public Gtk.Button Button => _button;

        public NetworkTrayWidget(NetworkService service, BarWindow? barWindow = null)
        {
            _barWindow = barWindow;
            _button = Gtk.Button.New();
            _button.AddCssClass("network-tray-button");

            var label = Gtk.Label.New("󰤨");
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

            // Right-click: toggle Wi-Fi
            var rightClick = Gtk.GestureClick.New();
            rightClick.SetButton(3);
            rightClick.OnReleased += (_, _) =>
            {
                _ = service.ToggleWifiAsync();
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

        private static void UpdateIcon(Gtk.Label label, NetworkService service)
        {
            label.RemoveCssClass("net-disconnected");
            label.RemoveCssClass("net-ethernet");
            label.RemoveCssClass("net-wifi-off");
            label.RemoveCssClass("net-wifi");

            var connectedDevice = service.Devices.FirstOrDefault(d => d.State == NetworkConnectionState.Connected);

            if (connectedDevice == null)
            {
                label.SetText("󰲛"); // Disconnected
                label.AddCssClass("net-disconnected");
            }
            else if (connectedDevice.DeviceType == NetworkDeviceType.Ethernet)
            {
                label.SetText("󰈀"); // Ethernet
                label.AddCssClass("net-ethernet");
            }
            else if (!service.IsWifiEnabled)
            {
                label.SetText("󰤯"); // Wi-Fi off
                label.AddCssClass("net-wifi-off");
            }
            else
            {
                label.AddCssClass("net-wifi");
                label.SetText(service.WifiSignalStrength switch
                {
                    < 25 => "󰤟",
                    < 50 => "󰤢",
                    < 75 => "󰤥",
                    _ => "󰤨"
                });
            }
        }
    }
}
