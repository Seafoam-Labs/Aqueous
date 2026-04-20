using System;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Aqueous.Bindings.AstalGTK4.Services;
using Gtk;

namespace Aqueous.Features.Brightness
{
    public class BrightnessService
    {
        private readonly BrightnessPopup _popup;
        private CancellationTokenSource? _cts;

        private static readonly string SocketPath =
            Path.Combine(Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR")
                ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".run"),
                "aqueous-brightness.sock");

        public event Action? BrightnessChanged;
        public event Action? PopupClosed;

        public bool IsPopupVisible => _popup.IsVisible;

        public BrightnessService(AstalApplication app)
        {
            _popup = new BrightnessPopup(app);
        }

        public void Start()
        {
            _cts = new CancellationTokenSource();
            Task.Run(() => ListenAsync(_cts.Token));
        }

        public void Stop()
        {
            _cts?.Cancel();
            CleanupSocket();
        }

        public void Toggle(Button? anchor = null)
        {
            if (_popup.IsVisible)
            {
                _popup.Hide();
                PopupClosed?.Invoke();
            }
            else
            {
                _popup.Show(anchor);
            }
        }

        public void Hide()
        {
            _popup.Hide();
            PopupClosed?.Invoke();
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
                catch (OperationCanceledException)
                {
                    break;
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"[Brightness] ListenAsync failed: {ex.Message}");
                }
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

                string response = "ok";

                switch (command)
                {
                    case "toggle-popup":
                        GLib.Functions.IdleAdd(0, () => { Toggle(null); return false; });
                        break;
                    case "show":
                        GLib.Functions.IdleAdd(0, () => { _popup.Show(null); return false; });
                        break;
                    case "hide":
                        GLib.Functions.IdleAdd(0, () => { Hide(); return false; });
                        break;
                    case "get":
                        var percent = await BrightnessBackend.GetBrightnessPercentAsync();
                        response = percent.ToString();
                        break;
                    case "up":
                        var currentUp = await BrightnessBackend.GetBrightnessPercentAsync();
                        var newUp = Math.Min(currentUp + 5, 100);
                        await BrightnessBackend.SetBrightnessAsync(newUp);
                        response = newUp.ToString();
                        GLib.Functions.IdleAdd(0, () => { BrightnessChanged?.Invoke(); return false; });
                        break;
                    case "down":
                        var currentDown = await BrightnessBackend.GetBrightnessPercentAsync();
                        var newDown = Math.Max(currentDown - 5, 0);
                        await BrightnessBackend.SetBrightnessAsync(newDown);
                        response = newDown.ToString();
                        GLib.Functions.IdleAdd(0, () => { BrightnessChanged?.Invoke(); return false; });
                        break;
                    default:
                        if (command.StartsWith("set "))
                        {
                            var value = command["set ".Length..].Trim();
                            if (int.TryParse(value, out var setPercent))
                            {
                                await BrightnessBackend.SetBrightnessAsync(setPercent);
                                GLib.Functions.IdleAdd(0, () => { BrightnessChanged?.Invoke(); return false; });
                            }
                            else
                            {
                                await BrightnessBackend.SetBrightnessAsync(value);
                                GLib.Functions.IdleAdd(0, () => { BrightnessChanged?.Invoke(); return false; });
                            }
                        }
                        else
                        {
                            response = "unknown command";
                        }
                        break;
                }

                await client.SendAsync(Encoding.UTF8.GetBytes(response + "\n"));
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[Brightness] HandleClientAsync failed: {ex.Message}");
            }
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
