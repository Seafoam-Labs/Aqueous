using System;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Aqueous.Bindings.AstalGTK4.Services;

namespace Aqueous.Features.Settings
{
    public class SettingsService
    {
        private readonly SettingsWindow _window;
        private readonly SettingsStore _store;
        private CancellationTokenSource? _cts;

        private static readonly string SocketPath =
            Path.Combine(Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR")
                ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".run"),
                "aqueous-settings.sock");

        public SettingsStore Store => _store;

        public SettingsService(AstalApplication app)
        {
            _store = SettingsStore.Instance;
            _store.Load();
            _window = new SettingsWindow(app, _store);
        }

        public void Start()
        {
            _cts = new CancellationTokenSource();
            Task.Run(() => ListenAsync(_cts.Token));
        }

        public void Stop()
        {
            _store.Save();
            _cts?.Cancel();
            CleanupSocket();
        }

        public void Toggle()
        {
            _window.Toggle();
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
                catch
                {
                    // Continue listening on transient errors
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

                switch (command)
                {
                    case "toggle":
                        GLib.Functions.IdleAdd(0, () => { Toggle(); return false; });
                        break;
                    case "show":
                        GLib.Functions.IdleAdd(0, () => { _window.Show(); return false; });
                        break;
                    case "hide":
                        GLib.Functions.IdleAdd(0, () => { _window.Hide(); return false; });
                        break;
                }

                await client.SendAsync(Encoding.UTF8.GetBytes("ok\n"));
            }
            catch
            {
                // Ignore client errors
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
