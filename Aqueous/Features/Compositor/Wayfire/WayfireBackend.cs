using System;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Aqueous.Features.SnapTo;

namespace Aqueous.Features.Compositor.Wayfire
{
    /// <summary>
    /// <see cref="ICompositorBackend"/> adapter over the existing static
    /// <see cref="WayfireIpc"/> methods and <see cref="WayfireEventClient"/>.
    ///
    /// This exists only to bridge the old surface into the new abstraction so
    /// that callers can be migrated incrementally. It adds no new behavior.
    /// </summary>
    public sealed class WayfireBackend : ICompositorBackend
    {
        private CancellationTokenSource? _cts;
        private Task? _eventLoop;
        private bool _started;

        public event Action? ViewsChanged;
        public event Action? WorkspaceChanged;

        public Task<JsonElement[]> ListViews() => WayfireIpc.ListViews();
        public Task<JsonElement?> GetFocusedView() => WayfireIpc.GetFocusedView();
        public Task FocusView(int viewId) => WayfireIpc.FocusView(viewId);
        public Task CloseView(int viewId) => WayfireIpc.CloseView(viewId);
        public Task MinimizeView(int viewId, bool minimized) => WayfireIpc.MinimizeView(viewId, minimized);
        public Task SetViewGeometry(int viewId, int x, int y, int w, int h) =>
            WayfireIpc.SetViewGeometry(viewId, x, y, w, h);
        public Task<JsonElement[]> ListOutputs() => WayfireIpc.ListOutputs();
        public Task<(int X, int Y)?> GetCursorPosition() => WayfireIpc.GetCursorPosition();
        public Task<JsonElement> GetWorkspace() => WayfireIpc.GetWorkspace();
        public Task SetWorkspace(int x, int y) => WayfireIpc.SetWorkspace(x, y);

        public void Start()
        {
            if (_started) return;
            _started = true;
            _cts = new CancellationTokenSource();
            _eventLoop = Task.Run(() => EventLoop(_cts.Token));
        }

        private async Task EventLoop(CancellationToken ct)
        {
            // Best-effort subscription; mirrors what SnapToService / WindowManagerService
            // already do ad-hoc. Failures just mean no push events — callers can still poll.
            while (!ct.IsCancellationRequested)
            {
                try
                {
                    using var client = new WayfireEventClient();
                    client.Connect();
                    await client.Subscribe(new[] { "view-mapped", "view-unmapped", "view-focused", "view-geometry-changed", "view-workspace-changed" });
                    while (!ct.IsCancellationRequested)
                    {
                        var evt = await client.ReadMessage(ct);
                        if (evt.TryGetProperty("event", out var name))
                        {
                            var s = name.GetString();
                            if (s is "view-workspace-changed")
                                WorkspaceChanged?.Invoke();
                            else
                                ViewsChanged?.Invoke();
                        }
                    }
                }
                catch (OperationCanceledException) { return; }
                catch
                {
                    // Socket dropped / Wayfire not running — back off and retry.
                    try { await Task.Delay(1000, ct); } catch { return; }
                }
            }
        }

        public void Dispose()
        {
            try { _cts?.Cancel(); } catch { }
            try { _eventLoop?.Wait(500); } catch { }
            _cts?.Dispose();
        }
    }
}
