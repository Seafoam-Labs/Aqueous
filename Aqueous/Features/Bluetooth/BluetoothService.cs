using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Aqueous.Bindings.AstalGTK4.Services;

namespace Aqueous.Features.Bluetooth
{
    public class BluetoothService
    {
        private readonly BluetoothBackend _backend;
        private readonly BluetoothPopup _popup;
        private CancellationTokenSource? _cts;

        private static readonly string SocketPath =
            Path.Combine(Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR")
                ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".run"),
                "aqueous-bluetooth.sock");

        public event Action? StateChanged;
        public event Action? PopupClosed;

        public bool IsAdapterPowered { get; private set; }
        public List<BluetoothDevice> Devices { get; private set; } = new();

        public BluetoothService(AstalApplication app)
        {
            _backend = new BluetoothBackend();
            _popup = new BluetoothPopup(app, _backend);

            _backend.DevicesChanged += () =>
            {
                _ = RefreshStateAsync();
            };
            _backend.AdapterStateChanged += () =>
            {
                _ = RefreshStateAsync();
            };
        }

        public void Start()
        {
            _cts = new CancellationTokenSource();
            Task.Run(async () =>
            {
                for (int attempt = 0; attempt < 5; attempt++)
                {
                    try
                    {
                        await _backend.ConnectAsync();
                        await RefreshStateAsync();
                        return; // Success
                    }
                    catch (Exception ex)
                    {
                        Console.Error.WriteLine($"[Bluetooth] Start attempt {attempt + 1} failed: {ex.Message}");
                        _backend.ResetConnection();
                        await Task.Delay(2000);
                    }
                }
                Console.Error.WriteLine("[Bluetooth] All connection attempts failed.");
            });

            // Periodic state refresh as a safety net (every 10 seconds)
            GLib.Functions.TimeoutAdd(0, 10000, () =>
            {
                _ = RefreshStateAsync();
                return true;
            });
            Task.Run(() => ListenAsync(_cts.Token));
        }

        public void Stop()
        {
            _cts?.Cancel();
            _backend.Dispose();
            CleanupSocket();
        }

        public bool IsPopupVisible => _popup.IsVisible;

        public void Toggle(Gtk.Button? anchorButton = null)
        {
            if (_popup.IsVisible)
            {
                _popup.Hide();
                PopupClosed?.Invoke();
            }
            else
            {
                _popup.Show(anchorButton);
            }
        }

        public void Show(Gtk.Button? anchorButton = null) => _popup.Show(anchorButton);

        public async Task TogglePowerAsync()
        {
            var powered = await _backend.GetAdapterPoweredAsync();
            await _backend.SetAdapterPoweredAsync(!powered);
        }

        public void Hide()
        {
            _popup.Hide();
            PopupClosed?.Invoke();
        }

        private async Task RefreshStateAsync()
        {
            try
            {
                IsAdapterPowered = await _backend.GetAdapterPoweredAsync();
                Devices = await _backend.GetDevicesAsync();
                GLib.Functions.IdleAdd(0, () => { StateChanged?.Invoke(); return false; });
            }
            catch (Exception ex) { Console.Error.WriteLine($"[Bluetooth] RefreshStateAsync failed: {ex.Message}"); }
        }

        private async Task ListenAsync(CancellationToken ct)
        {
            CleanupSocket();
            using var listener = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
            listener.Bind(new UnixDomainSocketEndPoint(SocketPath));
            listener.Listen(5);

            while (!ct.IsCancellationRequested)
            {
                try
                {
                    var client = await listener.AcceptAsync(ct);
                    _ = HandleClientAsync(client);
                }
                catch (OperationCanceledException) { break; }
                catch (Exception ex) { Console.Error.WriteLine($"[Bluetooth] ListenAsync failed: {ex.Message}"); }
            }

            CleanupSocket();
        }

        private async Task HandleClientAsync(Socket client)
        {
            try
            {
                var buffer = new byte[256];
                var received = await client.ReceiveAsync(buffer);
                var command = Encoding.UTF8.GetString(buffer, 0, received).Trim();

                switch (command)
                {
                    case "toggle":
                        GLib.Functions.IdleAdd(0, () => { Toggle(); return false; });
                        break;
                    case "show":
                        GLib.Functions.IdleAdd(0, () => { _popup.Show(); return false; });
                        break;
                    case "hide":
                        GLib.Functions.IdleAdd(0, () => { Hide(); return false; });
                        break;
                }

                await client.SendAsync(Encoding.UTF8.GetBytes("ok\n"));
            }
            catch (Exception ex) { Console.Error.WriteLine($"[Bluetooth] HandleClientAsync failed: {ex.Message}"); }
            finally
            {
                client.Dispose();
            }
        }

        private static void CleanupSocket()
        {
            try { File.Delete(SocketPath); } catch { }
        }
    }
}
