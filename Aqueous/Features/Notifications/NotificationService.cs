using System;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Aqueous.Bindings.AstalGTK4.Services;

namespace Aqueous.Features.Notifications
{
    public class NotificationService
    {
        private readonly NotificationBackend _backend;
        private readonly NotificationPopup _popup;
        private readonly NotificationCenter _center;
        private CancellationTokenSource? _cts;

        private static readonly string SocketPath =
            Path.Combine(Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR")
                ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".run"),
                "aqueous-notifications.sock");

        public event Action? StateChanged;
        public event Action? CenterClosed;

        public int UnreadCount { get; private set; }
        public bool IsCenterVisible => _center.IsVisible;

        public NotificationService(AstalApplication app)
        {
            _backend = new NotificationBackend();
            _popup = new NotificationPopup(app);
            _center = new NotificationCenter(app, _backend);

            _backend.NotificationReceived += notification =>
            {
                UnreadCount++;
                if (!_backend.DontDisturb)
                    _popup.ShowNotification(notification);
                _center.Refresh();
                GLib.Functions.IdleAdd(0, () => { StateChanged?.Invoke(); return false; });
            };

            _backend.NotificationClosed += (id, reason) =>
            {
                _popup.RemovePopup(id);
                _center.Refresh();
                GLib.Functions.IdleAdd(0, () => { StateChanged?.Invoke(); return false; });
            };

            _center.Closed += () =>
            {
                CenterClosed?.Invoke();
            };
        }

        public void Start()
        {
            _cts = new CancellationTokenSource();
            Task.Run(() => ListenAsync(_cts.Token));
        }

        public void Stop()
        {
            _cts?.Cancel();
            _backend.Dispose();
            CleanupSocket();
        }

        public void Toggle(Gtk.Button? anchorButton = null)
        {
            if (_center.IsVisible)
            {
                _center.Hide();
            }
            else
            {
                UnreadCount = 0;
                _center.Show(anchorButton);
                GLib.Functions.IdleAdd(0, () => { StateChanged?.Invoke(); return false; });
            }
        }

        public void Show(Gtk.Button? anchorButton = null) => _center.Show(anchorButton);

        public void Hide()
        {
            _center.Hide();
        }

        public void DismissAll()
        {
            var notifications = _backend.GetNotifications();
            foreach (var n in notifications)
                n.Dismiss();
            UnreadCount = 0;
            GLib.Functions.IdleAdd(0, () => { StateChanged?.Invoke(); return false; });
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
                catch (Exception ex) { Console.Error.WriteLine($"[Notifications] ListenAsync failed: {ex.Message}"); }
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
                        GLib.Functions.IdleAdd(0, () => { _center.Show(); return false; });
                        break;
                    case "hide":
                        GLib.Functions.IdleAdd(0, () => { Hide(); return false; });
                        break;
                    case "dismiss-all":
                        GLib.Functions.IdleAdd(0, () => { DismissAll(); return false; });
                        break;
                    case "dnd-on":
                        _backend.DontDisturb = true;
                        GLib.Functions.IdleAdd(0, () => { StateChanged?.Invoke(); return false; });
                        break;
                    case "dnd-off":
                        _backend.DontDisturb = false;
                        GLib.Functions.IdleAdd(0, () => { StateChanged?.Invoke(); return false; });
                        break;
                }

                await client.SendAsync(Encoding.UTF8.GetBytes("ok\n"));
            }
            catch (Exception ex) { Console.Error.WriteLine($"[Notifications] HandleClientAsync failed: {ex.Message}"); }
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
