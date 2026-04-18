using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Aqueous.Helpers;
using Gtk;

namespace Aqueous.Features.Network
{
    public class NetworkPopup
    {
        private readonly AstalApplication _app;
        private readonly NetworkBackend _backend;
        private AstalWindow? _window;
        private AstalWindow? _backdrop;
        private Gtk.Box? _apListContainer;
        private Gtk.Box? _mainContainer;
        private Action? _devicesChangedHandler;
        private uint _refreshDebounce;

        public bool IsVisible { get; private set; }

        public NetworkPopup(AstalApplication app, NetworkBackend backend)
        {
            _app = app;
            _backend = backend;
        }

        public void Show()
        {
            if (IsVisible) return;
            IsVisible = true;

            if (!_backend.IsConnected)
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    BuildNotConnectedWindow();
                    return false;
                });
                return;
            }

            Task.Run(async () =>
            {
                try
                {
                    var wifiEnabled = await _backend.GetWirelessEnabledAsync();
                    var devices = await _backend.GetDevicesAsync();

                    // Request scan on first Wi-Fi device
                    var wifiDevice = devices.FirstOrDefault(d => d.DeviceType == NetworkDeviceType.Wifi);
                    if (wifiDevice != null && wifiEnabled)
                        await _backend.RequestScanAsync(wifiDevice.Interface);

                    // Give NM time to return scan results
                    await Task.Delay(1000);

                    var accessPoints = new List<WifiAccessPoint>();
                    if (wifiDevice != null && wifiEnabled)
                        accessPoints = await _backend.GetAccessPointsAsync(wifiDevice.Interface);

                    GLib.Functions.IdleAdd(0, () =>
                    {
                        BuildWindow(wifiEnabled, devices, accessPoints);
                        return false;
                    });
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"[Network] Show() failed: {ex.Message}");
                    IsVisible = false;
                }
            });
        }

        private void BuildWindow(bool wifiEnabled, List<NetworkDevice> devices, List<WifiAccessPoint> accessPoints)
        {
            _window = new AstalWindow();
            _app.GtkApplication.AddWindow(_window.GtkWindow);
            _window.Namespace = "network-popup";
            _window.Layer = AstalLayer.ASTAL_LAYER_OVERLAY;
            _window.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_IGNORE;
            _window.Keymode = AstalKeymode.ASTAL_KEYMODE_ON_DEMAND;
            _window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP
                           | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT;

            _mainContainer = Gtk.Box.New(Orientation.Vertical, 4);
            _mainContainer.AddCssClass("network-popup");

            // Header with Wi-Fi toggle
            var header = Gtk.Box.New(Orientation.Horizontal, 8);
            header.AddCssClass("network-header");

            var title = Gtk.Label.New("Network");
            title.AddCssClass("section-header");
            title.Hexpand = true;
            title.Halign = Align.Start;
            header.Append(title);

            var wifiSwitch = Gtk.Switch.New();
            wifiSwitch.Active = wifiEnabled;
            wifiSwitch.Valign = Align.Center;
            wifiSwitch.OnStateSet += (sender, args) =>
            {
                _ = _backend.SetWirelessEnabledAsync(args.State);
                GLib.Functions.TimeoutAdd(0, 500, () => { Hide(); Show(); return false; });
                return false;
            };
            header.Append(wifiSwitch);
            _mainContainer.Append(header);

            // Connected devices section
            var connected = devices.FindAll(d => d.State == NetworkConnectionState.Connected);
            if (connected.Count > 0)
            {
                var connHeader = Gtk.Label.New("Connected");
                connHeader.AddCssClass("section-header");
                connHeader.Halign = Align.Start;
                _mainContainer.Append(connHeader);

                foreach (var dev in connected)
                    _mainContainer.Append(CreateDeviceRow(dev));
            }

            if (wifiEnabled)
            {
                // Scan button
                var wifiDevice = devices.FirstOrDefault(d => d.DeviceType == NetworkDeviceType.Wifi);
                if (wifiDevice != null)
                {
                    var scanBtn = Gtk.Button.New();
                    scanBtn.AddCssClass("network-scan-btn");
                    var scanLabel = Gtk.Label.New("Scan for Networks");
                    scanBtn.SetChild(scanLabel);
                    scanBtn.OnClicked += async (_, _) =>
                    {
                        await _backend.RequestScanAsync(wifiDevice.Interface);
                        Hide();
                        Show();
                    };
                    _mainContainer.Append(scanBtn);
                }

                // Build access point list
                RebuildAccessPointList(accessPoints, devices);

                // Subscribe to device changes for live updates
                _devicesChangedHandler = () =>
                {
                    // Debounce popup refresh to avoid flooding wayland buffer
                    if (_refreshDebounce != 0)
                        GLib.Functions.SourceRemove(_refreshDebounce);
                    _refreshDebounce = GLib.Functions.TimeoutAdd(0, 1000, () =>
                    {
                        _refreshDebounce = 0;
                        Task.Run(async () =>
                        {
                            try
                            {
                                var newDevices = await _backend.GetDevicesAsync();
                                var newWifiDevice = newDevices.FirstOrDefault(d => d.DeviceType == NetworkDeviceType.Wifi);
                                var newAps = new List<WifiAccessPoint>();
                                if (newWifiDevice != null)
                                    newAps = await _backend.GetAccessPointsAsync(newWifiDevice.Interface);
                                GLib.Functions.IdleAdd(0, () =>
                                {
                                    RebuildAccessPointList(newAps, newDevices);
                                    return false;
                                });
                            }
                            catch (Exception ex)
                            {
                                Console.Error.WriteLine($"[Network] Live refresh failed: {ex.Message}");
                            }
                        });
                        return false;
                    });
                };
                _backend.DevicesChanged += _devicesChangedHandler;
            }
            else
            {
                var offLabel = Gtk.Label.New("Wi-Fi is turned off");
                offLabel.AddCssClass("network-off-label");
                _mainContainer.Append(offLabel);
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
            scrolled.SetChild(_mainContainer);

            _backdrop = BackdropHelper.CreateBackdrop(_app, "network-backdrop", AstalLayer.ASTAL_LAYER_OVERLAY, Hide);

            _window.GtkWindow.SetChild(scrolled);
            _window.GtkWindow.Present();
        }

        private void RebuildAccessPointList(List<WifiAccessPoint> accessPoints, List<NetworkDevice> devices)
        {
            if (_mainContainer == null) return;

            if (_apListContainer != null)
                _mainContainer.Remove(_apListContainer);

            _apListContainer = Gtk.Box.New(Orientation.Vertical, 4);

            // Deduplicate by SSID, keep strongest signal, limit to 15 to avoid wayland buffer overflow
            var uniqueAps = accessPoints
                .GroupBy(ap => ap.Ssid)
                .Select(g => g.OrderByDescending(ap => ap.Strength).First())
                .OrderByDescending(ap => ap.Strength)
                .Take(15)
                .ToList();

            var wifiDevice = devices.FirstOrDefault(d => d.DeviceType == NetworkDeviceType.Wifi);

            if (uniqueAps.Count > 0)
            {
                var apHeader = Gtk.Label.New("Available Networks");
                apHeader.AddCssClass("section-header");
                apHeader.Halign = Align.Start;
                _apListContainer.Append(apHeader);

                foreach (var ap in uniqueAps)
                    _apListContainer.Append(CreateAccessPointRow(ap, wifiDevice));
            }
            else
            {
                var emptyLabel = Gtk.Label.New("No networks found");
                emptyLabel.AddCssClass("network-empty-label");
                _apListContainer.Append(emptyLabel);
            }

            _mainContainer.Append(_apListContainer);
        }

        private void BuildNotConnectedWindow()
        {
            _window = new AstalWindow();
            _app.GtkApplication.AddWindow(_window.GtkWindow);
            _window.Namespace = "network-popup";
            _window.Layer = AstalLayer.ASTAL_LAYER_OVERLAY;
            _window.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_IGNORE;
            _window.Keymode = AstalKeymode.ASTAL_KEYMODE_ON_DEMAND;
            _window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP
                           | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT;

            var container = Gtk.Box.New(Orientation.Vertical, 4);
            container.AddCssClass("network-popup");

            var label = Gtk.Label.New("Connecting to network service...");
            label.AddCssClass("network-empty-label");
            container.Append(label);

            var keyController = Gtk.EventControllerKey.New();
            keyController.OnKeyPressed += (controller, args) =>
            {
                if (args.Keyval == 0xff1b) { Hide(); return true; }
                return false;
            };
            _window.GtkWindow.AddController(keyController);

            _backdrop = BackdropHelper.CreateBackdrop(_app, "network-backdrop", AstalLayer.ASTAL_LAYER_OVERLAY, Hide);

            _window.GtkWindow.SetChild(container);
            _window.GtkWindow.Present();

            GLib.Functions.TimeoutAdd(0, 1000, () =>
            {
                if (!IsVisible) return false;
                if (_backend.IsConnected)
                {
                    Hide();
                    Show();
                    return false;
                }
                return true;
            });
        }

        public void Hide()
        {
            if (!IsVisible || _window == null) return;

            if (_devicesChangedHandler != null)
            {
                _backend.DevicesChanged -= _devicesChangedHandler;
                _devicesChangedHandler = null;
            }

            if (_refreshDebounce != 0)
            {
                GLib.Functions.SourceRemove(_refreshDebounce);
                _refreshDebounce = 0;
            }

            BackdropHelper.DestroyBackdrop(ref _backdrop);
            _window.GtkWindow.Close();
            _window = null;
            _mainContainer = null;
            _apListContainer = null;
            IsVisible = false;
        }

        private Gtk.Box CreateDeviceRow(NetworkDevice device)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("network-device-row");

            var iconLabel = Gtk.Label.New(GetDeviceIcon(device));
            iconLabel.AddCssClass("network-device-icon");
            row.Append(iconLabel);

            var nameLabel = Gtk.Label.New(
                string.IsNullOrEmpty(device.ActiveConnectionName)
                    ? device.Interface
                    : device.ActiveConnectionName);
            nameLabel.Hexpand = true;
            nameLabel.Halign = Align.Start;
            nameLabel.AddCssClass("network-device-name");
            row.Append(nameLabel);

            var statusLabel = Gtk.Label.New(device.State.ToString());
            statusLabel.AddCssClass("network-device-status");
            if (device.State == NetworkConnectionState.Connected)
                statusLabel.AddCssClass("connected");
            row.Append(statusLabel);

            return row;
        }

        private Gtk.Box CreateAccessPointRow(WifiAccessPoint ap, NetworkDevice? wifiDevice)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("network-ap-row");

            // Signal strength icon
            var signalIcon = Gtk.Label.New(GetSignalIcon(ap.Strength));
            signalIcon.AddCssClass("network-signal-icon");
            row.Append(signalIcon);

            // SSID
            var ssidLabel = Gtk.Label.New(ap.Ssid);
            ssidLabel.Hexpand = true;
            ssidLabel.Halign = Align.Start;
            ssidLabel.AddCssClass("network-ap-ssid");
            row.Append(ssidLabel);

            // Lock icon if secured
            if (ap.IsSecured)
            {
                var lockLabel = Gtk.Label.New("󰌾");
                lockLabel.AddCssClass("network-lock-icon");
                row.Append(lockLabel);
            }

            // Connect button
            var connectBtn = Gtk.Button.New();
            connectBtn.SetChild(Gtk.Label.New("Connect"));
            connectBtn.AddCssClass("network-connect-btn");
            connectBtn.OnClicked += (_, _) =>
            {
                if (wifiDevice == null) return;
                _ = Task.Run(async () =>
                {
                    var devicePath = await _backend.FindDevicePathAsync(wifiDevice.Interface);
                    if (devicePath == null) return;

                    if (ap.IsSecured)
                    {
                        GLib.Functions.IdleAdd(0, () =>
                        {
                            ShowPasswordDialog(ap, devicePath);
                            return false;
                        });
                    }
                    else
                    {
                        await _backend.ActivateConnectionAsync(ap.NetworkName, devicePath);
                        GLib.Functions.IdleAdd(0, () => { Hide(); return false; });
                    }
                });
            };
            row.Append(connectBtn);

            return row;
        }

        private void ShowPasswordDialog(WifiAccessPoint ap, string devicePath)
        {
            if (_mainContainer == null) return;

            // Replace AP list with password entry
            if (_apListContainer != null)
                _mainContainer.Remove(_apListContainer);

            _apListContainer = Gtk.Box.New(Orientation.Vertical, 8);
            _apListContainer.AddCssClass("network-password-container");

            var promptLabel = Gtk.Label.New($"Password for {ap.Ssid}:");
            promptLabel.Halign = Align.Start;
            promptLabel.AddCssClass("network-password-prompt");
            _apListContainer.Append(promptLabel);

            var entry = Gtk.Entry.New();
            entry.SetVisibility(false);
            entry.SetPlaceholderText("Enter password");
            entry.AddCssClass("network-password-entry");
            _apListContainer.Append(entry);

            var btnBox = Gtk.Box.New(Orientation.Horizontal, 8);

            var cancelBtn = Gtk.Button.New();
            cancelBtn.SetChild(Gtk.Label.New("Cancel"));
            cancelBtn.AddCssClass("network-cancel-btn");
            cancelBtn.OnClicked += (_, _) => { Hide(); Show(); };
            btnBox.Append(cancelBtn);

            var connectBtn = Gtk.Button.New();
            connectBtn.SetChild(Gtk.Label.New("Connect"));
            connectBtn.AddCssClass("network-connect-btn");
            connectBtn.OnClicked += (_, _) =>
            {
                var password = entry.GetText();
                if (!string.IsNullOrEmpty(password))
                {
                    _ = _backend.ConnectToNewWifiAsync(ap.Ssid, password, devicePath);
                    Hide();
                }
            };
            btnBox.Append(connectBtn);

            _apListContainer.Append(btnBox);
            _mainContainer.Append(_apListContainer);

            entry.GrabFocus();
        }

        private static string GetDeviceIcon(NetworkDevice device)
        {
            if (device.DeviceType == NetworkDeviceType.Ethernet)
                return "󰈀";
            if (device.DeviceType == NetworkDeviceType.Wifi)
                return GetSignalIcon(device.SignalStrength);
            return "󰲛";
        }

        private static string GetSignalIcon(int strength)
        {
            return strength switch
            {
                < 25 => "󰤟",
                < 50 => "󰤢",
                < 75 => "󰤥",
                _ => "󰤨"
            };
        }
    }
}
