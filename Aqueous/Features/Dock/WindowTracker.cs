using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Aqueous.Features.WindowManager;

namespace Aqueous.Features.Dock
{
    public class WindowTracker : IDisposable
    {
        private readonly WindowManagerService _windowManager;
        private HashSet<string> _runningApps = new();
        private Dictionary<string, string> _appIdToDesktopId = new();

        public event Action<HashSet<string>>? RunningAppsChanged;

        public WindowTracker(WindowManagerService windowManager)
        {
            _windowManager = windowManager;
        }

        public void Start()
        {
            BuildAppIdIndex();
            _windowManager.WindowsChanged += OnWindowsChanged;
            // Initial sync
            OnWindowsChanged();
        }

        public void Stop()
        {
            _windowManager.WindowsChanged -= OnWindowsChanged;
        }

        public HashSet<string> GetRunningApps() => new(_runningApps);

        public void Dispose()
        {
            Stop();
        }

        private void BuildAppIdIndex()
        {
            _appIdToDesktopId.Clear();

            var appDirs = new[]
            {
                "/usr/share/applications",
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                             ".local/share/applications")
            };

            foreach (var dir in appDirs)
            {
                if (!Directory.Exists(dir)) continue;

                foreach (var file in Directory.GetFiles(dir, "*.desktop"))
                {
                    try
                    {
                        var desktopId = Path.GetFileNameWithoutExtension(file);
                        string? wmClass = null;
                        string? exec = null;
                        string? type = null;
                        bool noDisplay = false;
                        bool inDesktopEntry = false;

                        foreach (var line in File.ReadLines(file))
                        {
                            var trimmed = line.Trim();
                            if (trimmed.StartsWith("["))
                            {
                                inDesktopEntry = trimmed == "[Desktop Entry]";
                                continue;
                            }

                            if (!inDesktopEntry) continue;

                            if (trimmed.StartsWith("StartupWMClass=") && wmClass == null)
                                wmClass = trimmed.Substring(15).Trim();
                            else if (trimmed.StartsWith("Exec=") && exec == null)
                            {
                                exec = trimmed.Substring(5);
                                exec = System.Text.RegularExpressions.Regex.Replace(exec, @"\s*%[uUfFdDnNickvm]", "").Trim();
                            }
                            else if (trimmed.StartsWith("Type="))
                                type = trimmed.Substring(5).Trim();
                            else if (trimmed.Equals("NoDisplay=true", StringComparison.OrdinalIgnoreCase))
                                noDisplay = true;
                        }

                        if (type != null && type != "Application") continue;
                        if (noDisplay) continue;

                        // Map by StartupWMClass (preferred), then by desktop file id, then by binary name
                        if (wmClass != null && !_appIdToDesktopId.ContainsKey(wmClass.ToLowerInvariant()))
                            _appIdToDesktopId[wmClass.ToLowerInvariant()] = desktopId;

                        if (!_appIdToDesktopId.ContainsKey(desktopId.ToLowerInvariant()))
                            _appIdToDesktopId[desktopId.ToLowerInvariant()] = desktopId;

                        if (exec != null)
                        {
                            var binary = Path.GetFileName(exec.Split(' ')[0]);
                            if (!string.IsNullOrEmpty(binary) && !_appIdToDesktopId.ContainsKey(binary.ToLowerInvariant()))
                                _appIdToDesktopId[binary.ToLowerInvariant()] = desktopId;
                        }
                    }
                    catch
                    {
                        // Skip unreadable .desktop files
                    }
                }
            }
        }

        private void OnWindowsChanged()
        {
            var windows = _windowManager.Windows;
            var current = new HashSet<string>();

            foreach (var win in windows)
            {
                if (string.IsNullOrEmpty(win.AppId)) continue;
                if (win.Role != "toplevel") continue;

                var appIdLower = win.AppId.ToLowerInvariant();

                if (_appIdToDesktopId.TryGetValue(appIdLower, out var desktopId))
                    current.Add(desktopId);
                else
                    current.Add(win.AppId);
            }

            if (!current.SetEquals(_runningApps))
            {
                _runningApps = current;
                RunningAppsChanged?.Invoke(new HashSet<string>(current));
            }
        }
    }
}
