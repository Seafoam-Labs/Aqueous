using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Aqueous.Bindings.AstalGTK4.Services;
using Aqueous.Features.Settings;
using Aqueous.Features.WindowManager;
using Aqueous.Widgets.Dock;

namespace Aqueous.Features.Dock
{
    public class DockService
    {
        private readonly AstalApplication _app;
        private readonly SettingsService _settingsService;
        private readonly WindowManagerService _windowManager;
        private DockWindow? _window;
        private WindowTracker? _windowTracker;
        private readonly Dictionary<string, Gtk.Widget> _runningAppWidgets = new();

        public DockService(AstalApplication app, SettingsService settingsService, WindowManagerService windowManager)
        {
            _app = app;
            _settingsService = settingsService;
            _windowManager = windowManager;
        }

        public void Start()
        {
            var position = ParsePosition(_settingsService.Store.Data.DockPosition);
            _window = new DockWindow(_app, position);
            _window.Show();

            _settingsService.Store.Changed += OnSettingsChanged;

            _windowTracker = new WindowTracker(_windowManager);
            _windowTracker.RunningAppsChanged += OnRunningAppsChanged;
            _windowTracker.Start();
        }

        public void Stop()
        {
            _settingsService.Store.Changed -= OnSettingsChanged;
            _windowTracker?.Stop();
            _windowTracker?.Dispose();
            _windowTracker = null;
            _window?.Hide();
            _window = null;
        }

        public void SetPosition(DockPosition position)
        {
            _runningAppWidgets.Clear();
            _window?.Rebuild(position);
            // Re-apply running apps after rebuild
            if (_windowTracker != null)
            {
                UpdateRunningApps(_windowTracker.GetRunningApps());
            }
        }

        private void OnRunningAppsChanged(HashSet<string> runningApps)
        {
            GLib.Functions.IdleAdd(0, () =>
            {
                UpdateRunningApps(runningApps);
                return false;
            });
        }

        private void UpdateRunningApps(HashSet<string> runningApps)
        {
            if (_window == null) return;

            // Remove widgets for apps no longer running
            var toRemove = _runningAppWidgets.Keys
                .Where(id => !runningApps.Contains(id))
                .ToList();
            foreach (var id in toRemove)
            {
                _window.RemoveItem(_runningAppWidgets[id]);
                _runningAppWidgets.Remove(id);
            }

            // Add widgets for newly opened apps
            foreach (var appId in runningApps)
            {
                if (_runningAppWidgets.ContainsKey(appId)) continue;

                var desktopPath = FindDesktopFile(appId);
                
                string name = appId;
                string icon = "application-x-executable";
                string exec = "";
                string windowAppId = appId;

                if (desktopPath != null)
                {
                    var parsed = ParseDesktopFile(desktopPath);
                    name = parsed.name ?? name;
                    icon = parsed.icon ?? icon;
                    exec = parsed.exec ?? exec;

                    var windowAppIds = _windowTracker?.GetAppIdsForDesktopId(appId);
                    if (windowAppIds?.Count > 0)
                    {
                        windowAppId = windowAppIds[0];
                    }
                }

                var item = new DockItemWidget(
                    name,
                    icon,
                    exec,
                    _windowManager,
                    windowAppId);
                    
                item.Button.AddCssClass("dock-item-running");
                _window.AddItem(item.Button);
                _runningAppWidgets[appId] = item.Button;
            }
        }

        private string? FindDesktopFile(string appId)
        {
            var appDirs = new[]
            {
                "/usr/share/applications",
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                             ".local/share/applications"),
                "/var/lib/flatpak/exports/share/applications",
                "/var/lib/snapd/desktop/applications",
                "/usr/local/share/applications"
            };

            foreach (var dir in appDirs)
            {
                var path = Path.Combine(dir, appId + ".desktop");
                if (File.Exists(path)) return path;

                if (Directory.Exists(dir))
                {
                    foreach (var file in Directory.GetFiles(dir, "*.desktop"))
                    {
                        if (Path.GetFileNameWithoutExtension(file)
                            .Equals(appId, StringComparison.OrdinalIgnoreCase))
                            return file;
                    }
                }
            }
            return null;
        }

        private static (string? name, string? icon, string? exec) ParseDesktopFile(string path)
        {
            string? name = null;
            string? icon = null;
            string? exec = null;
            bool inDesktopEntry = false;

            foreach (var line in File.ReadLines(path))
            {
                var trimmed = line.Trim();
                if (trimmed.StartsWith("["))
                {
                    inDesktopEntry = trimmed == "[Desktop Entry]";
                    continue;
                }

                if (!inDesktopEntry) continue;

                if (trimmed.StartsWith("Name=") && name == null)
                    name = trimmed.Substring(5);
                else if (trimmed.StartsWith("Icon=") && icon == null)
                    icon = trimmed.Substring(5);
                else if (trimmed.StartsWith("Exec=") && exec == null)
                {
                    exec = trimmed.Substring(5);
                    exec = System.Text.RegularExpressions.Regex.Replace(exec, @"\s*%[uUfFdDnNickvm]", "").Trim();
                }
            }

            return (name, icon, exec);
        }

        private void OnSettingsChanged()
        {
            var newPosition = ParsePosition(_settingsService.Store.Data.DockPosition);
            GLib.Functions.IdleAdd(0, () =>
            {
                SetPosition(newPosition);
                return false;
            });
        }

        private static DockPosition ParsePosition(string value)
        {
            return value switch
            {
                "Bottom" => DockPosition.Bottom,
                "Right" => DockPosition.Right,
                "Hidden" => DockPosition.Hidden,
                _ => DockPosition.Left,
            };
        }
    }
}
