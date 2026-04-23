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
        private readonly AstalApplication _app;
        private SnapToOverlay _overlay;
        private CancellationTokenSource? _cts;

        private static readonly string SocketPath =
            Path.Combine(Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR")
                ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".run"),
                "aqueous-snapto.sock");

        public AstalApplication App => _app;

        public SnapToService(AstalApplication app)
        {
            _app = app;
            var layouts = SnapToConfig.Load();
            _overlay = new SnapToOverlay(app, layouts);
        }

        public void ReloadLayouts()
        {
            var wasVisible = _overlay.IsVisible;
            if (wasVisible) _overlay.Hide();
            var layouts = SnapToConfig.Load();
            _overlay = new SnapToOverlay(_app, layouts);
            if (wasVisible) _overlay.Show();
        }

        public void ShowEditor(string? preSelectedZone = null)
        {
            var editor = new SnapToEditorPopup(_app, SnapToConfig.Load());
            editor.OnSaved = ReloadLayouts;
            editor.Show(preSelectedZone);
        }

        public void Start()
        {
            _cts = new CancellationTokenSource();
            var backend = Aqueous.Features.Compositor.CompositorBackend.Current;
            Console.WriteLine($"[SnapTo] backend={backend.GetType().Name} caps={backend.Capabilities}");
            var ct = _cts.Token;
            _ = Task.Run(async () => await ListenAsync(ct));
            _ = Task.Run(async () => await ListenDragSnapAsync(ct));
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
                    case "edit":
                        GLib.Functions.IdleAdd(0, () => { ShowEditor(); return false; });
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

        private async Task ListenDragSnapAsync(CancellationToken ct)
        {
            var backend = Aqueous.Features.Compositor.CompositorBackend.Current;
            if (!backend.Capabilities.HasFlag(Aqueous.Features.Compositor.CompositorCapabilities.DragSnapEvents))
            {
                Console.WriteLine("[SnapTo] DragSnap disabled: backend lacks DragSnapEvents capability.");
                return;
            }

            // River backend doesn't support DragSnapEvents yet, so this will just return
            // Wait indefinitely to not exit the task prematurely
            await Task.Delay(Timeout.Infinite, ct);
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
