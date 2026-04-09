using System;
using System.Collections.Generic;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Gtk;

namespace Aqueous.Features.Bluetooth
{
    public class BluetoothPopup
    {
        private readonly AstalApplication _app;
        private readonly BluetoothBackend _backend;
        private AstalWindow? _window;

        public bool IsVisible { get; private set; }

        public BluetoothPopup(AstalApplication app, BluetoothBackend backend)
        {
            _app = app;
            _backend = backend;
        }

        public void Show()
        {
            if (IsVisible) return;
            IsVisible = true;

            Task.Run(async () =>
            {
                try
                {
                    var powered = await _backend.GetAdapterPoweredAsync();
                    var discovering = await _backend.GetDiscoveringAsync();
                    var devices = await _backend.GetDevicesAsync();

                    GLib.Functions.IdleAdd(0, () =>
                    {
                        BuildWindow(powered, discovering, devices);
                        return false;
                    });
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"[Bluetooth] Show() failed: {ex.Message}");
                    IsVisible = false;
                }
            });
        }

        private void BuildWindow(bool powered, bool discovering, List<BluetoothDevice> devices)
        {
            _window = new AstalWindow();
            _app.GtkApplication.AddWindow(_window.GtkWindow);
            _window.Namespace = "bluetooth-popup";
            _window.Layer = AstalLayer.ASTAL_LAYER_OVERLAY;
            _window.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_IGNORE;
            _window.Keymode = AstalKeymode.ASTAL_KEYMODE_ON_DEMAND;
            _window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP
                           | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT;

            var container = Gtk.Box.New(Orientation.Vertical, 4);
            container.AddCssClass("bluetooth-popup");

            // Header with power toggle
            var header = Gtk.Box.New(Orientation.Horizontal, 8);
            header.AddCssClass("bluetooth-header");

            var title = Gtk.Label.New("Bluetooth");
            title.AddCssClass("section-header");
            title.Hexpand = true;
            title.Halign = Align.Start;
            header.Append(title);

            var powerSwitch = Gtk.Switch.New();
            powerSwitch.Active = powered;
            powerSwitch.Valign = Align.Center;
            powerSwitch.OnStateSet += (sender, args) =>
            {
                _ = _backend.SetAdapterPoweredAsync(args.State);
                // Refresh after a short delay
                GLib.Functions.TimeoutAdd(0, 500, () => { Hide(); Show(); return false; });
                return false;
            };
            header.Append(powerSwitch);
            container.Append(header);

            if (powered)
            {
                // Scan button
                var scanBtn = Gtk.Button.New();
                scanBtn.AddCssClass("bluetooth-scan-btn");
                var scanLabel = Gtk.Label.New(discovering ? "Stop Scanning" : "Scan for Devices");
                scanBtn.SetChild(scanLabel);
                scanBtn.OnClicked += async (_, _) =>
                {
                    if (discovering)
                        await _backend.StopDiscoveryAsync();
                    else
                        await _backend.StartDiscoveryAsync();
                    Hide();
                    Show();
                };
                container.Append(scanBtn);

                // Connected devices
                var connected = devices.FindAll(d => d.IsConnected);
                if (connected.Count > 0)
                {
                    var connHeader = Gtk.Label.New("Connected");
                    connHeader.AddCssClass("section-header");
                    connHeader.Halign = Align.Start;
                    container.Append(connHeader);
                    foreach (var dev in connected)
                        container.Append(CreateDeviceRow(dev));
                }

                // Paired devices (not connected)
                var paired = devices.FindAll(d => d.IsPaired && !d.IsConnected);
                if (paired.Count > 0)
                {
                    var pairedHeader = Gtk.Label.New("Paired");
                    pairedHeader.AddCssClass("section-header");
                    pairedHeader.Halign = Align.Start;
                    container.Append(pairedHeader);
                    foreach (var dev in paired)
                        container.Append(CreateDeviceRow(dev));
                }

                // Discovered devices (not paired)
                var discovered = devices.FindAll(d => !d.IsPaired);
                if (discovered.Count > 0)
                {
                    var discHeader = Gtk.Label.New("Available");
                    discHeader.AddCssClass("section-header");
                    discHeader.Halign = Align.Start;
                    container.Append(discHeader);
                    foreach (var dev in discovered)
                        container.Append(CreateDeviceRow(dev));
                }
            }
            else
            {
                var offLabel = Gtk.Label.New("Bluetooth is turned off");
                offLabel.AddCssClass("bluetooth-off-label");
                container.Append(offLabel);
            }

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

            var scrolled = Gtk.ScrolledWindow.New();
            scrolled.SetPolicy(PolicyType.Never, PolicyType.Automatic);
            scrolled.SetMaxContentHeight(400);
            scrolled.SetPropagateNaturalHeight(true);
            scrolled.SetChild(container);

            _window.GtkWindow.SetChild(scrolled);
            _window.GtkWindow.Present();
        }

        public void Hide()
        {
            if (!IsVisible || _window == null) return;
            _window.GtkWindow.Close();
            _window = null;
            IsVisible = false;
        }

        private Gtk.Box CreateDeviceRow(BluetoothDevice device)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("bluetooth-device-row");

            // Device icon
            var iconLabel = Gtk.Label.New(GetDeviceIcon(device.Icon));
            iconLabel.AddCssClass("bluetooth-device-icon");
            row.Append(iconLabel);

            // Device name
            var nameLabel = Gtk.Label.New(device.Name);
            nameLabel.Hexpand = true;
            nameLabel.Halign = Align.Start;
            nameLabel.AddCssClass("bluetooth-device-name");
            row.Append(nameLabel);

            // Status indicator
            var statusLabel = Gtk.Label.New(device.Status.ToString());
            statusLabel.AddCssClass("bluetooth-device-status");
            if (device.IsConnected)
                statusLabel.AddCssClass("connected");
            row.Append(statusLabel);

            // Action button
            var actionBtn = Gtk.Button.New();
            if (device.IsConnected)
            {
                actionBtn.SetChild(Gtk.Label.New("Disconnect"));
                actionBtn.AddCssClass("bluetooth-disconnect-btn");
                actionBtn.OnClicked += async (_, _) =>
                {
                    await _backend.DisconnectDeviceAsync(device.Address);
                    Hide();
                    Show();
                };
            }
            else if (device.IsPaired)
            {
                actionBtn.SetChild(Gtk.Label.New("Connect"));
                actionBtn.AddCssClass("bluetooth-connect-btn");
                actionBtn.OnClicked += async (_, _) =>
                {
                    await _backend.ConnectDeviceAsync(device.Address);
                    Hide();
                    Show();
                };
            }
            else
            {
                actionBtn.SetChild(Gtk.Label.New("Pair"));
                actionBtn.AddCssClass("bluetooth-pair-btn");
                actionBtn.OnClicked += async (_, _) =>
                {
                    await _backend.PairDeviceAsync(device.Address);
                    Hide();
                    Show();
                };
            }
            row.Append(actionBtn);

            return row;
        }

        private static string GetDeviceIcon(string icon)
        {
            return icon switch
            {
                "audio-headphones" => "🎧",
                "audio-headset" => "🎧",
                "input-keyboard" => "⌨",
                "input-mouse" => "🖱",
                "input-gaming" => "🎮",
                "phone" => "📱",
                "computer" => "💻",
                _ => "󰂯"
            };
        }
    }
}
