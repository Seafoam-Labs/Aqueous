using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Aqueous.Bindings.AstalRiver.Services;

namespace Aqueous.Features.Compositor.River
{
    /// <summary>
    /// River compositor backend — Phase 3 scaffolding.
    ///
    /// Read side is wired against <see cref="AstalRiverRiver"/> (status only).
    /// Write side (close / focus / geometry / workspace commands) intentionally
    /// throws <see cref="NotSupportedException"/> until Phase 4 lands the
    /// <c>riverctl</c> + <c>wlr-foreign-toplevel-management-v1</c> plumbing.
    ///
    /// The <see cref="WorkspaceChanged"/> / <see cref="ViewsChanged"/> events
    /// are driven by a polling loop for now — AstalRiver exposes GObject
    /// signals but GIR binding into C# for those is not yet generated, so a
    /// tight poll (200 ms) on focused-tags + focused-view is pragmatic and
    /// gets replaced with signal subscription as soon as bindings grow.
    /// </summary>
    public sealed class RiverBackend : ICompositorBackend
    {
        private readonly AstalRiverRiver? _river;
        private CancellationTokenSource? _cts;
        private Task? _pollLoop;
        private bool _started;

        // Last-seen state used to detect changes between polls.
        private uint _lastFocusedTags;
        private string? _lastFocusedView;
        private string? _lastOutputName;

        public event Action? ViewsChanged;
        public event Action? WorkspaceChanged;

        public RiverBackend()
        {
            _river = AstalRiverRiver.GetDefault();
        }

        /// <summary>True when libastal-river is reachable (i.e. running under River).</summary>
        public bool IsAvailable => _river != null;

        // ---------- Read side (live) ----------

        public Task<JsonElement> GetWorkspace()
        {
            var output = _river?.FocusedOutput;
            uint mask = output?.FocusedTags ?? 0;
            // Compatibility view: expose the lowest set tag index as (x, y) with gridW=9.
            int idx = mask == 0 ? 0 : System.Numerics.BitOperations.TrailingZeroCount(mask);
            int x = idx % 3;
            int y = idx / 3;
            var json = $"{{\"x\":{x},\"y\":{y},\"workspace_size\":{{\"width\":3,\"height\":3}},\"tag_mask\":{mask}}}";
            using var doc = JsonDocument.Parse(json);
            return Task.FromResult(doc.RootElement.Clone());
        }

        public Task<JsonElement[]> ListOutputs()
        {
            var results = new List<JsonElement>();
            if (_river != null)
            {
                foreach (var o in _river.Outputs)
                {
                    var json = $"{{\"name\":\"{Escape(o.Name)}\",\"focused_tags\":{o.FocusedTags},\"occupied_tags\":{o.OccupiedTags},\"urgent_tags\":{o.UrgentTags},\"layout\":\"{Escape(o.Layout)}\",\"focused\":{(o.Focused ? "true" : "false")}}}";
                    using var doc = JsonDocument.Parse(json);
                    results.Add(doc.RootElement.Clone());
                }
            }
            return Task.FromResult(results.ToArray());
        }

        public Task<JsonElement?> GetFocusedView()
        {
            var title = _river?.FocusedView;
            if (string.IsNullOrEmpty(title)) return Task.FromResult<JsonElement?>(null);
            var json = $"{{\"title\":\"{Escape(title)}\"}}";
            using var doc = JsonDocument.Parse(json);
            return Task.FromResult<JsonElement?>(doc.RootElement.Clone());
        }

        public Task<JsonElement[]> ListViews()
        {
            // AstalRiver is status-only and does not enumerate views. Phase 4 will
            // populate this list from wlr-foreign-toplevel-management-v1.
            return Task.FromResult(Array.Empty<JsonElement>());
        }

        public Task<(int X, int Y)?> GetCursorPosition()
        {
            // Not exposed by AstalRiver; River has no cursor IPC. Callers must
            // fall back to Gdk pointer query. Return null so SnapTo can detect.
            return Task.FromResult<(int X, int Y)?>(null);
        }

        // ---------- Write side (Phase 4) ----------

        public Task FocusView(int viewId) => throw CmdNotImpl(nameof(FocusView));
        public Task CloseView(int viewId) => throw CmdNotImpl(nameof(CloseView));
        public Task MinimizeView(int viewId, bool minimized) => throw CmdNotImpl(nameof(MinimizeView));
        public Task SetViewGeometry(int viewId, int x, int y, int w, int h) => throw CmdNotImpl(nameof(SetViewGeometry));
        public Task SetWorkspace(int x, int y) => throw CmdNotImpl(nameof(SetWorkspace));

        private static NotSupportedException CmdNotImpl(string op) =>
            new($"RiverBackend.{op} is not implemented yet (Phase 4: riverctl + wlr-foreign-toplevel).");

        // ---------- Polling lifecycle ----------

        public void Start()
        {
            if (_started || _river == null) return;
            _started = true;
            _cts = new CancellationTokenSource();
            _pollLoop = Task.Run(() => PollLoop(_cts.Token));
        }

        private async Task PollLoop(CancellationToken ct)
        {
            while (!ct.IsCancellationRequested)
            {
                try
                {
                    var output = _river?.FocusedOutput;
                    var tags = output?.FocusedTags ?? 0;
                    var outName = output?.Name;
                    var title = _river?.FocusedView;

                    if (tags != _lastFocusedTags || outName != _lastOutputName)
                    {
                        _lastFocusedTags = tags;
                        _lastOutputName = outName;
                        WorkspaceChanged?.Invoke();
                    }
                    if (title != _lastFocusedView)
                    {
                        _lastFocusedView = title;
                        ViewsChanged?.Invoke();
                    }
                }
                catch
                {
                    // Poll-loop must never kill the process on a transient read.
                }
                try { await Task.Delay(200, ct); } catch { return; }
            }
        }

        private static string Escape(string? s) =>
            (s ?? string.Empty).Replace("\\", "\\\\").Replace("\"", "\\\"");

        public void Dispose()
        {
            try { _cts?.Cancel(); } catch { }
            try { _pollLoop?.Wait(500); } catch { }
            _cts?.Dispose();
        }
    }
}
