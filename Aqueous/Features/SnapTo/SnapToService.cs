using System;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Aqueous.Bindings.AstalGTK4.Services;

namespace Aqueous.Features.SnapTo
{
    public class SnapToService
    {
        private SnapToOverlay _overlay;
        private CancellationTokenSource? _cts;

        private static readonly string SocketPath =
            Path.Combine(Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR")
                ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".run"),
                "aqueous-snapto.sock");

        public SnapToService(AstalApplication app)
        {
            var layouts = SnapToConfig.Load();
            _overlay = new SnapToOverlay(app, layouts);
        }

        public void Start()
        {
            _cts = new CancellationTokenSource();
            Task.Run(() => ListenAsync(_cts.Token));
            Task.Run(() => ListenWayfireEventsAsync(_cts.Token));
        }

        public void Stop()
        {
            _cts?.Cancel();
            CleanupSocket();
        }

        public void Toggle()
        {
            if (_overlay.IsVisible) _overlay.Hide();
            else _overlay.Show();
        }

        public void CycleLayout() => _overlay.CycleLayout();

        public void Hide() => _overlay.Hide();

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

                // Marshal to GTK main thread via GLib.Functions.IdleAdd
                switch (command)
                {
                    case "toggle":
                        GLib.Functions.IdleAdd(0, () => { Toggle(); return false; });
                        break;
                    case "cycle":
                        GLib.Functions.IdleAdd(0, () => { CycleLayout(); return false; });
                        break;
                    case "hide":
                        GLib.Functions.IdleAdd(0, () => { Hide(); return false; });
                        break;
                    case "show":
                        GLib.Functions.IdleAdd(0, () => { _overlay.Show(); return false; });
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

        private async Task ListenWayfireEventsAsync(CancellationToken ct)
        {
            while (!ct.IsCancellationRequested)
            {
                try
                {
                    using var client = new WayfireEventClient();
                    client.Connect();
                    await client.Subscribe(["plugin-activation-state-changed"]);

                    while (!ct.IsCancellationRequested)
                    {
                        var evt = await client.ReadMessage(ct);

                        if (evt.TryGetProperty("event", out var eventName)
                            && eventName.GetString() == "plugin-activation-state-changed"
                            && evt.TryGetProperty("plugin", out var plugin)
                            && plugin.GetString() == "move"
                            && evt.TryGetProperty("state", out var state))
                        {
                            if (state.GetBoolean())
                            {
                                GLib.Functions.IdleAdd(0, () =>
                                {
                                    _overlay.Show(isDragMode: true);
                                    return false;
                                });
                            }
                            else
                            {
                                GLib.Functions.IdleAdd(0, () =>
                                {
                                    _ = SnapAndHideAsync();
                                    return false;
                                });
                            }
                        }
                    }
                }
                catch (OperationCanceledException) { break; }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"[SnapTo] Wayfire IPC error: {ex.Message}");
                    await Task.Delay(2000, ct);
                }
            }
        }

        private async Task SnapAndHideAsync()
        {
            await _overlay.SnapToZoneAtCursor();
            _overlay.Hide();
        }

        private static void CleanupSocket()
        {
            try { File.Delete(SocketPath); } catch { }
        }
    }
}
