using System;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Aqueous.Bindings.AstalAuth.Services;
using Aqueous.Bindings.AstalGTK4.Services;

namespace Aqueous.Features.Screenlock
{
    public class ScreenlockService
    {
        private readonly AstalApplication _app;
        private ScreenlockWindow? _window;
        private AstalAuthPam? _pam;
        private CancellationTokenSource? _cts;

        private static readonly string SocketPath =
            Path.Combine(Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR")
                ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".run"),
                "aqueous-screenlock.sock");

        public ScreenlockService(AstalApplication app)
        {
            _app = app;
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
            _pam?.Dispose();
        }

        public void Lock()
        {
            if (_window != null && _window.IsVisible) return;

            _window = new ScreenlockWindow(_app);
            _window.OnPasswordSubmitted += OnPasswordSubmitted;

            // Create PAM instance and wire up signals
            _pam?.Dispose();
            _pam = new AstalAuthPam();
            _pam.Username = Environment.UserName;
            _pam.Service = "login";

            _pam.OnSuccess += () =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    Unlock();
                    return false;
                });
            };

            _pam.OnFail += (msg) =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    _window?.SetStatus("Authentication failed. Try again.", true);
                    _window?.ClearPassword();
                    _window?.SetSensitive(true);
                    // Restart auth for next attempt
                    RestartAuth();
                    return false;
                });
            };

            _pam.OnAuthInfo += (msg) =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    _window?.SetStatus(msg, false);
                    return false;
                });
            };

            _pam.OnAuthError += (msg) =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    _window?.SetStatus(msg, true);
                    return false;
                });
            };

            _window.Show();
            _pam.StartAuthenticate();
        }

        public void Unlock()
        {
            _window?.Hide();
            _window = null;
            _pam?.Dispose();
            _pam = null;
        }

        private void OnPasswordSubmitted(string password)
        {
            if (_pam == null) return;
            _window?.SetSensitive(false);
            _window?.SetStatus("Authenticating...", false);
            _pam.SupplySecret(password);
        }

        private void RestartAuth()
        {
            if (_pam == null) return;
            // Create a fresh PAM instance for retry, preserving event handlers
            var oldPam = _pam;
            _pam = new AstalAuthPam();
            _pam.Username = Environment.UserName;
            _pam.Service = "login";

            _pam.OnSuccess += () =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    Unlock();
                    return false;
                });
            };

            _pam.OnFail += (msg) =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    _window?.SetStatus("Authentication failed. Try again.", true);
                    _window?.ClearPassword();
                    _window?.SetSensitive(true);
                    RestartAuth();
                    return false;
                });
            };

            _pam.OnAuthInfo += (msg) =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    _window?.SetStatus(msg, false);
                    return false;
                });
            };

            _pam.OnAuthError += (msg) =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    _window?.SetStatus(msg, true);
                    return false;
                });
            };

            oldPam.Dispose();
            _pam.StartAuthenticate();
        }

        private async Task ListenAsync(CancellationToken ct)
        {
            CleanupSocket();

            var directory = Path.GetDirectoryName(SocketPath);
            if (directory != null) Directory.CreateDirectory(directory);

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
                    case "lock":
                        GLib.Functions.IdleAdd(0, () => { Lock(); return false; });
                        break;
                    case "unlock":
                        GLib.Functions.IdleAdd(0, () => { Unlock(); return false; });
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
