using System;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Aqueous.Bindings.AstalGTK4.Services;
namespace Aqueous.Features.PowerProfiles
{
    public class PowerProfilesService
    {
        private readonly AstalApplication _app;
        private readonly PowerProfilesBackend _backend;
        private readonly PowerProfilesPopup _popup;
        private CancellationTokenSource? _cts;
        private static readonly string SocketPath =
            Path.Combine(Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR")
                ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".run"),
                "aqueous-powerprofiles.sock");
        public event Action? ProfileChanged;
        public event Action? PopupClosed;
        public PowerProfilesBackend Backend => _backend;
        public string? ActiveProfile => _backend.ActiveProfile;
        public string? IconName => _backend.IconName;
        public bool IsPopupVisible => _popup.IsVisible;
        public PowerProfilesService(AstalApplication app)
        {
            _app = app;
            _backend = new PowerProfilesBackend();
            _popup = new PowerProfilesPopup(app, _backend);
            _backend.ProfileChanged += () =>
            {
                GLib.Functions.IdleAdd(0, () => { ProfileChanged?.Invoke(); return false; });
            };
        }
        public void Start()
        {
            _cts = new CancellationTokenSource();
            _backend.Start();
            ProfileChanged?.Invoke();
            Task.Run(() => ListenAsync(_cts.Token));
        }
        public void Stop()
        {
            _cts?.Cancel();
            _backend.Dispose();
            CleanupSocket();
        }
        public void Toggle()
        {
            if (_popup.IsVisible)
            {
                _popup.Hide();
                PopupClosed?.Invoke();
            }
            else
            {
                _popup.Show();
            }
        }
        public void Hide()
        {
            _popup.Hide();
            PopupClosed?.Invoke();
        }
        public void CycleProfile()
        {
            _backend.CycleProfile();
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
                catch (Exception ex) { Console.Error.WriteLine($"[PowerProfiles] ListenAsync failed: {ex.Message}"); }
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
                        GLib.Functions.IdleAdd(0, () => { Toggle(); return false; });
                        break;
                    case "show":
                        GLib.Functions.IdleAdd(0, () => { _popup.Show(); return false; });
                        break;
                    case "hide":
                        GLib.Functions.IdleAdd(0, () => { Hide(); return false; });
                        break;
                    case "get-profile":
                        response = _backend.ActiveProfile ?? "unknown";
                        break;
                    case "list-profiles":
                        var profiles = _backend.Profiles;
                        if (profiles != null)
                        {
                            var sb = new StringBuilder();
                            foreach (var p in profiles)
                                sb.AppendLine(p.ProfileName ?? "unknown");
                            response = sb.ToString().TrimEnd();
                        }
                        else
                        {
                            response = "no profiles available";
                        }
                        break;
                    case "cycle":
                        GLib.Functions.IdleAdd(0, () => { _backend.CycleProfile(); return false; });
                        break;
                    default:
                        if (command.StartsWith("set-profile "))
                        {
                            var profile = command["set-profile ".Length..].Trim();
                            GLib.Functions.IdleAdd(0, () => { _backend.ActiveProfile = profile; return false; });
                        }
                        else
                        {
                            response = "unknown command";
                        }
                        break;
                }
                await client.SendAsync(Encoding.UTF8.GetBytes(response + "\n"));
            }
            catch (Exception ex) { Console.Error.WriteLine($"[PowerProfiles] HandleClientAsync failed: {ex.Message}"); }
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
