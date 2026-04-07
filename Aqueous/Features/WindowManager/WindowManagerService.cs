using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Aqueous.Features.SnapTo;

namespace Aqueous.Features.WindowManager
{
    public class WindowManagerService : IDisposable
    {
        private readonly Dictionary<int, TopLevelWindow> _windows = new();
        private CancellationTokenSource? _cts;
        private TopLevelWindow? _focusedWindow;

        public IReadOnlyList<TopLevelWindow> Windows
        {
            get
            {
                lock (_windows)
                    return _windows.Values.ToList();
            }
        }

        public TopLevelWindow? FocusedWindow
        {
            get
            {
                lock (_windows)
                    return _focusedWindow;
            }
        }

        public event Action? WindowsChanged;
        public event Action<TopLevelWindow>? WindowFocused;
        public event Action<TopLevelWindow>? WindowClosed;

        public void Start()
        {
            _cts = new CancellationTokenSource();
            Task.Run(() => InitAndListenAsync(_cts.Token));
        }

        public void Stop()
        {
            _cts?.Cancel();
        }

        public void Dispose()
        {
            Stop();
        }

        private async Task InitAndListenAsync(CancellationToken ct)
        {
            try
            {
                // Initial population
                var views = await WayfireIpc.ListViews();
                lock (_windows)
                {
                    foreach (var view in views)
                    {
                        var win = ParseView(view);
                        if (win != null)
                        {
                            _windows[win.Id] = win;
                            if (win.Focused)
                                _focusedWindow = win;
                        }
                    }
                }
                NotifyWindowsChanged();

                // Subscribe to events
                using var client = new WayfireEventClient();
                client.Connect();
                await client.Subscribe([
                    "view-mapped",
                    "view-unmapped",
                    "view-focused",
                    "view-title-changed",
                    "view-geometry-changed",
                    "view-minimized"
                ]);

                while (!ct.IsCancellationRequested)
                {
                    var evt = await client.ReadMessage(ct);
                    HandleEvent(evt);
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[WindowManager] Event loop error: {ex.Message}");
                // Retry after delay
                if (!ct.IsCancellationRequested)
                {
                    try { await Task.Delay(3000, ct); } catch { return; }
                    await InitAndListenAsync(ct);
                }
            }
        }

        private void HandleEvent(JsonElement evt)
        {
            if (!evt.TryGetProperty("event", out var eventName))
                return;

            var name = eventName.GetString();
            switch (name)
            {
                case "view-mapped":
                    if (evt.TryGetProperty("view", out var mappedView))
                    {
                        var win = ParseView(mappedView);
                        if (win != null)
                        {
                            lock (_windows)
                                _windows[win.Id] = win;
                            NotifyWindowsChanged();
                        }
                    }
                    break;

                case "view-unmapped":
                    if (evt.TryGetProperty("view", out var unmappedView))
                    {
                        var id = GetViewId(unmappedView);
                        if (id.HasValue)
                        {
                            TopLevelWindow? removed;
                            lock (_windows)
                            {
                                _windows.TryGetValue(id.Value, out removed);
                                _windows.Remove(id.Value);
                                if (_focusedWindow?.Id == id.Value)
                                    _focusedWindow = null;
                            }
                            if (removed != null)
                                WindowClosed?.Invoke(removed);
                            NotifyWindowsChanged();
                        }
                    }
                    break;

                case "view-focused":
                    if (evt.TryGetProperty("view", out var focusedView))
                    {
                        var id = GetViewId(focusedView);
                        lock (_windows)
                        {
                            foreach (var w in _windows.Values)
                                w.Focused = false;

                            if (id.HasValue && _windows.TryGetValue(id.Value, out var win))
                            {
                                win.Focused = true;
                                _focusedWindow = win;
                                WindowFocused?.Invoke(win);
                            }
                            else
                            {
                                _focusedWindow = null;
                            }
                        }
                        NotifyWindowsChanged();
                    }
                    break;

                case "view-title-changed":
                    if (evt.TryGetProperty("view", out var titleView))
                    {
                        var id = GetViewId(titleView);
                        if (id.HasValue)
                        {
                            lock (_windows)
                            {
                                if (_windows.TryGetValue(id.Value, out var win)
                                    && titleView.TryGetProperty("title", out var title))
                                {
                                    win.Title = title.GetString() ?? "";
                                }
                            }
                            NotifyWindowsChanged();
                        }
                    }
                    break;

                case "view-geometry-changed":
                    if (evt.TryGetProperty("view", out var geoView))
                    {
                        var id = GetViewId(geoView);
                        if (id.HasValue)
                        {
                            lock (_windows)
                            {
                                if (_windows.TryGetValue(id.Value, out var win)
                                    && geoView.TryGetProperty("geometry", out var geo))
                                {
                                    win.Geometry = ParseGeometry(geo);
                                }
                            }
                            NotifyWindowsChanged();
                        }
                    }
                    break;

                case "view-minimized":
                    if (evt.TryGetProperty("view", out var minView))
                    {
                        var id = GetViewId(minView);
                        if (id.HasValue)
                        {
                            lock (_windows)
                            {
                                if (_windows.TryGetValue(id.Value, out var win)
                                    && minView.TryGetProperty("minimized", out var minimized))
                                {
                                    win.Minimized = minimized.GetBoolean();
                                }
                            }
                            NotifyWindowsChanged();
                        }
                    }
                    break;
            }
        }

        private static TopLevelWindow? ParseView(JsonElement view)
        {
            if (!view.TryGetProperty("id", out var idProp))
                return null;

            var win = new TopLevelWindow
            {
                Id = idProp.GetInt32(),
                Title = view.TryGetProperty("title", out var t) ? t.GetString() ?? "" : "",
                AppId = view.TryGetProperty("app-id", out var a) ? a.GetString() ?? "" : "",
                OutputId = view.TryGetProperty("output-id", out var o) ? o.GetInt32() : -1,
                Focused = view.TryGetProperty("focused", out var f) && f.GetBoolean(),
                Minimized = view.TryGetProperty("minimized", out var m) && m.GetBoolean(),
                Fullscreen = view.TryGetProperty("fullscreen", out var fs) && fs.GetBoolean(),
                Role = view.TryGetProperty("role", out var r) ? r.GetString() ?? "" : "",
            };

            if (view.TryGetProperty("geometry", out var geo))
                win.Geometry = ParseGeometry(geo);

            if (view.TryGetProperty("workspace", out var ws))
            {
                win.WorkspaceX = ws.TryGetProperty("x", out var wx) ? wx.GetInt32() : 0;
                win.WorkspaceY = ws.TryGetProperty("y", out var wy) ? wy.GetInt32() : 0;
            }

            return win;
        }

        private static (int X, int Y, int W, int H) ParseGeometry(JsonElement geo)
        {
            var x = geo.TryGetProperty("x", out var gx) ? gx.GetInt32() : 0;
            var y = geo.TryGetProperty("y", out var gy) ? gy.GetInt32() : 0;
            var w = geo.TryGetProperty("width", out var gw) ? gw.GetInt32() : 0;
            var h = geo.TryGetProperty("height", out var gh) ? gh.GetInt32() : 0;
            return (x, y, w, h);
        }

        private static int? GetViewId(JsonElement view)
        {
            if (view.TryGetProperty("id", out var id))
                return id.GetInt32();
            return null;
        }

        private void NotifyWindowsChanged()
        {
            GLib.Functions.IdleAdd(0, () =>
            {
                WindowsChanged?.Invoke();
                return false;
            });
        }
    }
}
