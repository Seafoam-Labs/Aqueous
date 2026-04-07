using System;
using System.Text.Json;
using Aqueous.Features.SnapTo;
using Aqueous.Features.WindowManager;

namespace Aqueous.Widgets.WorkspaceSwitcher
{
    public class WorkspaceSwitcherWidget
    {
        private readonly WindowManagerService _windowManager;
        private readonly Gtk.Box _box;
        private int _currentX;
        private int _currentY;
        private int _gridW = 3;
        private int _gridH = 3;

        public Gtk.Box Box => _box;

        public WorkspaceSwitcherWidget(WindowManagerService windowManager)
        {
            _windowManager = windowManager;

            _box = Gtk.Box.New(Gtk.Orientation.Horizontal, 2);
            _box.AddCssClass("workspace-switcher");

            _windowManager.WindowsChanged += OnWindowsChanged;

            // Initial query
            _ = RefreshWorkspaceAsync();
        }

        private async System.Threading.Tasks.Task RefreshWorkspaceAsync()
        {
            try
            {
                var ws = await WayfireIpc.GetWorkspace();
                if (ws.TryGetProperty("x", out var x) && ws.TryGetProperty("y", out var y))
                {
                    _currentX = x.GetInt32();
                    _currentY = y.GetInt32();
                }
                if (ws.TryGetProperty("workspace_size", out var size))
                {
                    if (size.TryGetProperty("width", out var w)) _gridW = w.GetInt32();
                    if (size.TryGetProperty("height", out var h)) _gridH = h.GetInt32();
                }
            }
            catch
            {
                // Workspace query may not be available
            }

            GLib.Functions.IdleAdd(0, () =>
            {
                RebuildButtons();
                return false;
            });
        }

        private void OnWindowsChanged()
        {
            _ = RefreshWorkspaceAsync();
        }

        private void RebuildButtons()
        {
            // Remove existing children
            while (_box.GetFirstChild() != null)
            {
                var child = _box.GetFirstChild()!;
                _box.Remove(child);
            }

            for (int y = 0; y < _gridH; y++)
            {
                for (int x = 0; x < _gridW; x++)
                {
                    var btn = Gtk.Button.New();
                    btn.AddCssClass("workspace-dot");

                    if (x == _currentX && y == _currentY)
                        btn.AddCssClass("workspace-dot-active");

                    // Check if any window is on this workspace
                    var windows = _windowManager.Windows;
                    foreach (var win in windows)
                    {
                        if (win.WorkspaceX == x && win.WorkspaceY == y && win.Role == "toplevel")
                        {
                            btn.AddCssClass("workspace-dot-occupied");
                            break;
                        }
                    }

                    var wsX = x;
                    var wsY = y;
                    btn.OnClicked += (_, _) =>
                    {
                        _ = WayfireIpc.SetWorkspace(wsX, wsY);
                    };

                    _box.Append(btn);
                }
            }
        }
    }
}
