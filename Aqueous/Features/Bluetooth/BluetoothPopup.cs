using System;
using System.Collections.Generic;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Aqueous.Helpers;
using Gtk;

namespace Aqueous.Features.Bluetooth
{
    public class BluetoothPopup
    {
        private readonly AstalApplication _app;
        private readonly BluetoothBackend _backend;
        private AstalWindow? _window;
        private AstalWindow? _backdrop;
        private Gtk.Box? _deviceListContainer;
        private Gtk.Box? _mainContainer;
        private Action? _devicesChangedHandler;

        public bool IsVisible { get; private set; }

        public BluetoothPopup(AstalApplication app, BluetoothBackend backend)
        {
            _app = app;
            _backend = backend;
        }

        public void Show(Gtk.Button? anchorButton = null)
        {
            if (IsVisible) return;
            IsVisible = true;

            if (!_backend.IsConnected)
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    BuildNotConnectedWindow(anchorButton);
                    return false;
                });
                return;
            }

            Task.Run(async () =>
            {
                try
                {
                    var powered = await _backend.GetAdapterPoweredAsync();

                    // Auto-start discovery when popup opens
                    if (powered)
                        await _backend.StartDiscoveryAsync();

                    // Give BlueZ time to start returning discovery results
                    await Task.Delay(1000);

                    var discovering = await _backend.GetDiscoveringAsync();
                    var devices = await _backend.GetDevicesAsync();

                    GLib.Functions.IdleAdd(0, () =>
                    {
                        BuildWindow(powered, discovering, devices, anchorButton);
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

        private void BuildWindow(bool powered, bool discovering, List<BluetoothDevice> devices, Gtk.Button? anchorButton)
        {
            _window = new AstalWindow();
            _app.GtkApplication.AddWindow(_window.GtkWindow);
            _window.Namespace = "bluetooth-popup";
            _window.Layer = AstalLayer.ASTAL_LAYER_OVERLAY;
            _window.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_IGNORE;
            _window.Keymode = AstalKeymode.ASTAL_KEYMODE_ON_DEMAND;

            _mainContainer = Gtk.Box.New(Orientation.Vertical, 4);
            _mainContainer.AddCssClass("bluetooth-popup");

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
            _mainContainer.Append(header);

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
                _mainContainer.Append(scanBtn);

                // Build initial device list
                RebuildDeviceList(devices, discovering);

                // Subscribe to device changes for live updates
                _devicesChangedHandler = () =>
                {
                    Task.Run(async () =>
                    {
                        try
                        {
                            var newDevices = await _backend.GetDevicesAsync();
                            var newDiscovering = await _backend.GetDiscoveringAsync();
                            GLib.Functions.IdleAdd(0, () =>
                            {
                                RebuildDeviceList(newDevices, newDiscovering);
                                return false;
                            });
                        }
                        catch (Exception ex)
                        {
                            Console.Error.WriteLine($"[Bluetooth] Live refresh failed: {ex.Message}");
                        }
                    });
                };
                _backend.DevicesChanged += _devicesChangedHandler;
            }
            else
            {
                var offLabel = Gtk.Label.New("Bluetooth is turned off");
                offLabel.AddCssClass("bluetooth-off-label");
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

            if (anchorButton != null)
            {
                var (x, y) = WidgetGeometryHelper.GetWidgetGlobalPos(anchorButton);
                var (screenWidth, screenHeight) = WidgetGeometryHelper.GetScreenSize();

                scrolled.Measure(Orientation.Horizontal, -1, out _, out var natWidth, out _, out _);
                scrolled.Measure(Orientation.Vertical, -1, out _, out var natHeight, out _, out _);

                int popupWidth = Math.Max(320, natWidth);
                int popupHeight = Math.Min(400, natHeight);

                _window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_LEFT;

                int targetX = x + (anchorButton.GetAllocatedWidth() / 2) - (popupWidth / 2);
                int targetY = y + anchorButton.GetAllocatedHeight() + 4; // Tiny gap

                // Keep it on screen
                if (targetX + popupWidth > screenWidth - 10) targetX = screenWidth - popupWidth - 10;
                if (targetX < 10) targetX = 10;

                if (targetY + popupHeight > screenHeight - 10)
                {
                    targetY = Math.Max(10, y - popupHeight - 4);
                }

                _window.MarginLeft = targetX;
                _window.MarginTop = targetY;
            }
            else
            {
                _window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP
                               | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT;
            }

            _backdrop = BackdropHelper.CreateBackdrop(_app, "bluetooth-backdrop", AstalLayer.ASTAL_LAYER_OVERLAY, Hide);

            _window.GtkWindow.SetChild(scrolled);
            _window.GtkWindow.Present();
        }

        private void RebuildDeviceList(List<BluetoothDevice> devices, bool discovering)
        {
            if (_mainContainer == null) return;

            // Remove old device list container if present
            if (_deviceListContainer != null)
                _mainContainer.Remove(_deviceListContainer);

            _deviceListContainer = Gtk.Box.New(Orientation.Vertical, 4);

            // Connected devices
            var connected = devices.FindAll(d => d.IsConnected);
            if (connected.Count > 0)
            {
                var connHeader = Gtk.Label.New("Connected");
                connHeader.AddCssClass("section-header");
                connHeader.Halign = Align.Start;
                _deviceListContainer.Append(connHeader);
                foreach (var dev in connected)
                    _deviceListContainer.Append(CreateDeviceRow(dev));
            }

            // Paired devices (not connected)
            var paired = devices.FindAll(d => d.IsPaired && !d.IsConnected);
            if (paired.Count > 0)
            {
                var pairedHeader = Gtk.Label.New("Paired");
                pairedHeader.AddCssClass("section-header");
                pairedHeader.Halign = Align.Start;
                _deviceListContainer.Append(pairedHeader);
                foreach (var dev in paired)
                    _deviceListContainer.Append(CreateDeviceRow(dev));
            }

            // Discovered devices (not paired)
            var discovered = devices.FindAll(d => !d.IsPaired);
            if (discovered.Count > 0)
            {
                var discHeader = Gtk.Label.New("Available");
                discHeader.AddCssClass("section-header");
                discHeader.Halign = Align.Start;
                _deviceListContainer.Append(discHeader);
                foreach (var dev in discovered)
                    _deviceListContainer.Append(CreateDeviceRow(dev));
            }

            // Show placeholder if no devices found
            if (connected.Count == 0 && paired.Count == 0 && discovered.Count == 0)
            {
                var emptyLabel = Gtk.Label.New(discovering ? "Scanning..." : "No devices found");
                emptyLabel.AddCssClass("bluetooth-empty-label");
                _deviceListContainer.Append(emptyLabel);
            }

            _mainContainer.Append(_deviceListContainer);
        }

        private void BuildNotConnectedWindow(Gtk.Button? anchorButton)
        {
            _window = new AstalWindow();
            _app.GtkApplication.AddWindow(_window.GtkWindow);
            _window.Namespace = "bluetooth-popup";
            _window.Layer = AstalLayer.ASTAL_LAYER_OVERLAY;
            _window.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_IGNORE;
            _window.Keymode = AstalKeymode.ASTAL_KEYMODE_ON_DEMAND;

            var container = Gtk.Box.New(Orientation.Vertical, 4);
            container.AddCssClass("bluetooth-popup");

            var label = Gtk.Label.New("Connecting to BlueZ...");
            label.AddCssClass("bluetooth-empty-label");
            container.Append(label);

            if (anchorButton != null)
            {
                var (x, y) = WidgetGeometryHelper.GetWidgetGlobalPos(anchorButton);
                var (screenWidth, screenHeight) = WidgetGeometryHelper.GetScreenSize();

                container.Measure(Orientation.Horizontal, -1, out var minWidth, out var natWidth, out _, out _);
                container.Measure(Orientation.Vertical, -1, out var minHeight, out var natHeight, out _, out _);

                int popupWidth = Math.Max(320, natWidth);
                int popupHeight = Math.Max(100, natHeight);

                _window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_LEFT;

                int targetX = x + (anchorButton.GetAllocatedWidth() / 2) - (popupWidth / 2);
                int targetY = y + anchorButton.GetAllocatedHeight();

                // Keep it on screen
                if (targetX + popupWidth > screenWidth) targetX = screenWidth - popupWidth - 10;
                if (targetX < 10) targetX = 10;

                if (targetY + popupHeight > screenHeight)
                {
                    targetY = Math.Max(0, y - popupHeight);
                }

                _window.MarginLeft = targetX;
                _window.MarginTop = targetY;
            }
            else
            {
                _window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP
                               | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT;
            }

            var keyController = Gtk.EventControllerKey.New();
            keyController.OnKeyPressed += (controller, args) =>
            {
                if (args.Keyval == 0xff1b) { Hide(); return true; }
                return false;
            };
            _window.GtkWindow.AddController(keyController);

            _backdrop = BackdropHelper.CreateBackdrop(_app, "bluetooth-backdrop", AstalLayer.ASTAL_LAYER_OVERLAY, Hide);

            _window.GtkWindow.SetChild(container);
            _window.GtkWindow.Present();

            // Poll every 1 second — auto-transition when connected
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

            // Unsubscribe from device changes
            if (_devicesChangedHandler != null)
            {
                _backend.DevicesChanged -= _devicesChangedHandler;
                _devicesChangedHandler = null;
            }

            // Auto-stop discovery when popup closes
            _ = _backend.StopDiscoveryAsync();

            BackdropHelper.DestroyBackdrop(ref _backdrop);
            _window.GtkWindow.Close();
            _window = null;
            _mainContainer = null;
            _deviceListContainer = null;
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
