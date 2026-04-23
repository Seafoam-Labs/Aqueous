using System;
using System.Collections.Generic;
using System.Collections.Immutable;
using System.Diagnostics;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Aqueous.Bindings.AstalRiver.Services;

namespace Aqueous.Features.Compositor.River
{
    /// <summary>
    /// River compositor backend.
    ///
    /// Read side is fully event-driven via <see cref="RiverStateAggregator"/>,
    /// which subscribes to GObject <c>notify::*</c> signals on the
    /// <c>AstalRiverRiver</c> singleton and its per-output children.
    ///
    /// Write side (Phase 4) shells out to <c>riverctl</c>. River does not
    /// expose per-view IDs, so view-targeted commands operate on the currently
    /// focused view; <see cref="MinimizeView"/> and <see cref="SetViewGeometry"/>
    /// are no-ops because River has no equivalent concepts.
    /// </summary>
    public sealed class RiverBackend : ICompositorBackend
    {
        private readonly AstalRiverRiver? _river;
        private readonly RiverStateAggregator? _agg;
        private RiverSnapshot _last = RiverSnapshot.Empty;

        // Phase 4b — optional wlr-foreign-toplevel client, gated behind
        // AQUEOUS_FOREIGN_TOPLEVEL=1. Off by default so the stable riverctl
        // path can't regress on production machines.
        private readonly ForeignToplevelClient? _toplevel;

        public event Action? ViewsChanged;
        public event Action? WorkspaceChanged;
        public event Action? OutputsChanged;

        // riverctl presence cached after first failed Start() on PATH.
        private static readonly Lazy<bool> _riverctlAvailable = new(() =>
        {
            try
            {
                var psi = new ProcessStartInfo("riverctl", "--help")
                {
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                };
                using var p = Process.Start(psi);
                if (p == null) return false;
                p.WaitForExit(500);
                return true;
            }
            catch { return false; }
        });

        public CompositorCapabilities Capabilities
        {
            get
            {
                var caps = CompositorCapabilities.None;
                if (_riverctlAvailable.Value)
                    caps |= CompositorCapabilities.TagMaskSwitch | CompositorCapabilities.ToggleFloat;
                if (_toplevel is { IsConnected: true })
                    caps |= CompositorCapabilities.ForeignToplevel;
                return caps;
            }
        }

        public Task SetFocusedTagMask(uint mask) =>
            RunRiverCtl("set-focused-tags", mask.ToString(System.Globalization.CultureInfo.InvariantCulture));

        public Task ToggleFloatingFocusedView() => RunRiverCtl("toggle-float");

        public Task<(int X, int Y, int W, int H)?> GetFocusedOutputGeometry()
        {
            // AstalRiver does not yet expose per-output logical geometry through
            // the snapshot; callers fall back to the Gdk monitor of the focused
            // window. Return null here rather than guessing.
            return Task.FromResult<(int X, int Y, int W, int H)?>(null);
        }

        public RiverBackend()
        {
            _river = AstalRiverRiver.GetDefault();
            if (_river != null)
            {
                _agg = new RiverStateAggregator(_river);
                _agg.Changed += OnSnapshotChanged;
            }

            // Optional: spin up the wlr-foreign-toplevel client.
            if (Environment.GetEnvironmentVariable("AQUEOUS_FOREIGN_TOPLEVEL") == "1")
            {
                _toplevel = ForeignToplevelClient.TryStart();
                if (_toplevel != null)
                {
                    _toplevel.Changed += () => { try { ViewsChanged?.Invoke(); } catch { } };
                }
            }
        }

        /// <summary>True when libastal-river is reachable (i.e. running under River).</summary>
        public bool IsAvailable => _river != null;

        // ---------- Typed read accessors (Phase 3) ----------

        public IReadOnlyList<CompositorOutput> Outputs => _last.Outputs;
        public CompositorOutput? FocusedOutput => _last.FocusedOutput;
        public CompositorFocusedView? FocusedViewInfo =>
            _last.FocusedViewTitle is { Length: > 0 } title
                ? new CompositorFocusedView(title, null, _last.FocusedOutputName)
                : null;
        public uint FocusedTagMask => _last.FocusedOutput?.FocusedTags ?? 0;
        public uint OccupiedTagMask => _last.FocusedOutput?.OccupiedTags ?? 0;
        public uint UrgentTagMask => _last.FocusedOutput?.UrgentTags ?? 0;
        public int LowestFocusedTagIndex =>
            FocusedTagMask == 0 ? -1 : System.Numerics.BitOperations.TrailingZeroCount(FocusedTagMask);

        // ---------- Legacy JSON-shape read methods ----------

        public Task<JsonElement> GetWorkspace()
        {
            uint mask = FocusedTagMask;
            int idx = mask == 0 ? 0 : System.Numerics.BitOperations.TrailingZeroCount(mask);
            int x = idx % 3;
            int y = idx / 3;
            var json = $"{{\"x\":{x},\"y\":{y},\"workspace_size\":{{\"width\":3,\"height\":3}},\"tag_mask\":{mask}}}";
            using var doc = JsonDocument.Parse(json);
            return Task.FromResult(doc.RootElement.Clone());
        }

        public Task<JsonElement[]> ListOutputs()
        {
            var results = new List<JsonElement>(_last.Outputs.Length);
            foreach (var o in _last.Outputs)
            {
                var json = $"{{\"name\":\"{Escape(o.Name)}\",\"focused_tags\":{o.FocusedTags},\"occupied_tags\":{o.OccupiedTags},\"urgent_tags\":{o.UrgentTags},\"layout\":\"{Escape(o.Layout)}\",\"focused\":{(o.Focused ? "true" : "false")}}}";
                using var doc = JsonDocument.Parse(json);
                results.Add(doc.RootElement.Clone());
            }
            return Task.FromResult(results.ToArray());
        }

        public Task<JsonElement?> GetFocusedView()
        {
            var title = _last.FocusedViewTitle;
            if (string.IsNullOrEmpty(title)) return Task.FromResult<JsonElement?>(null);
            var json = $"{{\"title\":\"{Escape(title)}\"}}";
            using var doc = JsonDocument.Parse(json);
            return Task.FromResult<JsonElement?>(doc.RootElement.Clone());
        }

        public Task<JsonElement[]> ListViews()
        {
            // Phase 4b: when AQUEOUS_FOREIGN_TOPLEVEL=1, ListViews is backed by
            // the hand-rolled wlr-foreign-toplevel-management-v1 client. When
            // off or no manager global is available, we return an empty array
            // (AstalRiver is status-only and does not enumerate views).
            if (_toplevel is not { IsConnected: true }) return Task.FromResult(Array.Empty<JsonElement>());
            var list = _toplevel.Toplevels;
            var results = new JsonElement[list.Count];
            for (int i = 0; i < list.Count; i++)
            {
                var t = list[i];
                var json = $"{{\"id\":{t.Id},\"title\":\"{Escape(t.Title)}\",\"app-id\":\"{Escape(t.AppId)}\",\"activated\":{(t.Activated ? "true" : "false")},\"minimized\":{(t.Minimized ? "true" : "false")}}}";
                using var doc = JsonDocument.Parse(json);
                results[i] = doc.RootElement.Clone();
            }
            return Task.FromResult(results);
        }

        public Task<(int X, int Y)?> GetCursorPosition()
        {
            // River has no cursor IPC; callers fall back to Gdk pointer query.
            return Task.FromResult<(int X, int Y)?>(null);
        }

        // ---------- Write side (Phase 4) ----------
        //
        // River drives all compositor mutations through the `riverctl` CLI. We
        // intentionally fire-and-forget: widgets don't need the result, and
        // blocking on a short-lived process would stall the GTK main loop.

        /// <summary>
        /// River does not expose per-view IDs, so <paramref name="viewId"/> is
        /// ignored and the command cycles focus to the next view on the
        /// currently focused output.
        /// </summary>
        public Task FocusView(int viewId) => RunRiverCtl("focus-view", "next");

        /// <summary>
        /// River does not expose per-view IDs, so <paramref name="viewId"/> is
        /// ignored and the currently focused view is closed.
        /// </summary>
        public Task CloseView(int viewId) => RunRiverCtl("close");

        /// <summary>No-op: River has no concept of minimized views.</summary>
        public Task MinimizeView(int viewId, bool minimized) => Task.CompletedTask;

        /// <summary>No-op: River is a dynamic tiler and does not support freeform geometry.</summary>
        public Task SetViewGeometry(int viewId, int x, int y, int w, int h) => Task.CompletedTask;

        /// <summary>
        /// Maps an (x, y) cell on the virtual 3×3 workspace grid to a River
        /// tag bitmask and asks River to focus that single tag on the focused
        /// output (via <c>riverctl set-focused-tags</c>).
        /// </summary>
        public Task SetWorkspace(int x, int y)
        {
            x = Math.Clamp(x, 0, 2);
            y = Math.Clamp(y, 0, 2);
            int idx = y * 3 + x;                     // 0..8, matches GetWorkspace()
            uint mask = 1u << idx;
            return RunRiverCtl("set-focused-tags", mask.ToString());
        }

        private static Task RunRiverCtl(params string[] args)
        {
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = "riverctl",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                };
                foreach (var a in args) psi.ArgumentList.Add(a);
                Process.Start(psi);
            }
            catch
            {
                // riverctl missing or failed to launch — swallow so widgets keep working.
            }
            return Task.CompletedTask;
        }

        // ---------- Lifecycle ----------

        public void Start()
        {
            if (_agg == null) return;
            _agg.Start();
            _last = _agg.Current;
        }

        private void OnSnapshotChanged(RiverSnapshot old, RiverSnapshot @new)
        {
            _last = @new;

            var oldF = old.FocusedOutput;
            var newF = @new.FocusedOutput;

            bool workspace =
                old.FocusedOutputName != @new.FocusedOutputName
                || oldF?.FocusedTags  != newF?.FocusedTags
                || oldF?.OccupiedTags != newF?.OccupiedTags
                || oldF?.UrgentTags   != newF?.UrgentTags;

            bool views =
                old.FocusedViewTitle != @new.FocusedViewTitle
                || old.FocusedOutputName != @new.FocusedOutputName;

            bool outputs = !old.Outputs.SequenceEqual(@new.Outputs);

            if (workspace) { try { WorkspaceChanged?.Invoke(); } catch { } }
            if (views)     { try { ViewsChanged?.Invoke();     } catch { } }
            if (outputs)   { try { OutputsChanged?.Invoke();   } catch { } }
        }

        private static string Escape(string? s) =>
            (s ?? string.Empty).Replace("\\", "\\\\").Replace("\"", "\\\"");

        public void Dispose()
        {
            _agg?.Dispose();
            _toplevel?.Dispose();
        }
    }
}
