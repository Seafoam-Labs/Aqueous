using System;
using System.Collections.Generic;
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
        public event Action? OutputsChanged;

        // --- Phase 3 typed accessors ---
        // Wayfire state is fetched lazily via JSON IPC (slow); we cache a best-effort
        // snapshot refreshed whenever WorkspaceChanged fires. Values default to "unknown"
        // (empty list / null / zero) on first access.
        private IReadOnlyList<CompositorOutput> _outputs = Array.Empty<CompositorOutput>();
        private CompositorOutput? _focusedOutput;
        private CompositorFocusedView? _focusedView;

        public IReadOnlyList<CompositorOutput> Outputs => _outputs;
        public CompositorOutput? FocusedOutput => _focusedOutput;
        public CompositorFocusedView? FocusedViewInfo => _focusedView;
        public uint FocusedTagMask => _focusedOutput?.FocusedTags ?? 0;
        public uint OccupiedTagMask => _focusedOutput?.OccupiedTags ?? 0;
        public uint UrgentTagMask => _focusedOutput?.UrgentTags ?? 0;
        public int LowestFocusedTagIndex =>
            FocusedTagMask == 0 ? -1 : System.Numerics.BitOperations.TrailingZeroCount(FocusedTagMask);

        private async Task RefreshTypedSnapshotAsync()
        {
            try
            {
                var outs = await WayfireIpc.ListOutputs();
                var list = new List<CompositorOutput>(outs.Length);
                foreach (var o in outs)
                {
                    string name = o.TryGetProperty("name", out var n) ? (n.GetString() ?? "") : "";
                    bool focused = o.TryGetProperty("focused", out var f) && f.ValueKind == JsonValueKind.True;
                    // Wayfire workspaces map to a 2D grid rather than tags — derive a tag-mask from
                    // the active workspace index so the typed surface is non-empty for widgets.
                    uint focusedTags = 0;
                    if (o.TryGetProperty("workspace", out var ws)
                        && ws.TryGetProperty("x", out var wx)
                        && ws.TryGetProperty("y", out var wy))
                    {
                        int idx = wx.GetInt32() + wy.GetInt32() * 3;
                        if (idx is >= 0 and < 32) focusedTags = 1u << idx;
                    }
                    list.Add(new CompositorOutput(name, focused, focusedTags, 0, 0, null));
                }
                _outputs = list;
                _focusedOutput = null;
                foreach (var o in list)
                    if (o.Focused) { _focusedOutput = o; break; }

                var fv = await WayfireIpc.GetFocusedView();
                if (fv is { } v && v.TryGetProperty("title", out var t))
                {
                    string? appId = v.TryGetProperty("app-id", out var ai) ? ai.GetString() : null;
                    _focusedView = new CompositorFocusedView(t.GetString() ?? "", appId, _focusedOutput?.Name);
                }
                else
                {
                    _focusedView = null;
                }
            }
            catch
            {
                // Best-effort; leave last-known snapshot in place.
            }
        }

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
            _ = RefreshTypedSnapshotAsync();
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
                            await RefreshTypedSnapshotAsync();
                            if (s is "view-workspace-changed")
                            {
                                WorkspaceChanged?.Invoke();
                                OutputsChanged?.Invoke();
                            }
                            else
                            {
                                ViewsChanged?.Invoke();
                            }
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
