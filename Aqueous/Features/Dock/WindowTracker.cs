using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace Aqueous.Features.Dock
{
    public class WindowTracker : IDisposable
    {
        private uint _pollTimeout;
        private HashSet<string> _runningApps = new();
        private Dictionary<string, string> _execToDesktopId = new();

        private static readonly HashSet<string> _backgroundProcesses = new(StringComparer.OrdinalIgnoreCase)
        {
            // Audio/media backends
            "pipewire", "pipewire-pulse", "wireplumber", "pulseaudio",
            // Portal/XDG services
            "xdg-desktop-portal", "xdg-desktop-portal-gtk", "xdg-desktop-portal-kde",
            "xdg-desktop-portal-wlr", "xdg-document-portal",
            // Tray applets
            "nm-applet", "blueman-applet", "blueman-tray", "pasystray",
            "udiskie", "cbatticon", "volumeicon",
            // Polkit / auth agents
            "polkit-kde-authentication-agent-1", "polkit-gnome-authentication-agent-1",
            "lxpolkit", "lxqt-policykit-agent",
            // Keyring / secrets
            "gnome-keyring-daemon", "ssh-agent", "gpg-agent",
            // Notification daemons
            "dunst", "mako", "swaync", "fnott",
            // Compositor helpers
            "waybar", "wf-panel", "wf-background", "wf-dock", "wf-shell",
            "swayidle", "swaylock", "gammastep", "wlsunset", "kanshi",
            // D-Bus / system
            "dbus-daemon", "dbus-broker", "at-spi-bus-launcher", "at-spi2-registryd",
            // IME
            "ibus-daemon", "fcitx5", "fcitx",
            // This shell itself
            "Aqueous", "aqueous",
        };

        public event Action<HashSet<string>>? RunningAppsChanged;

        public void Start()
        {
            BuildDesktopFileIndex();
            // Poll every 2 seconds
            _pollTimeout = GLib.Functions.TimeoutAdd(0, 2000, PollRunningApps);
        }

        public void Stop()
        {
            if (_pollTimeout != 0)
            {
                GLib.Functions.SourceRemove(_pollTimeout);
                _pollTimeout = 0;
            }
        }

        public HashSet<string> GetRunningApps() => new(_runningApps);

        public void Dispose()
        {
            Stop();
        }

        private void BuildDesktopFileIndex()
        {
            _execToDesktopId.Clear();

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

                            if (trimmed.StartsWith("Exec=") && exec == null)
                            {
                                exec = trimmed.Substring(5);
                                exec = System.Text.RegularExpressions.Regex.Replace(exec, @"\s*%[uUfFdDnNickvm]", "").Trim();
                            }
                            else if (trimmed.StartsWith("Type="))
                            {
                                type = trimmed.Substring(5).Trim();
                            }
                            else if (trimmed.Equals("NoDisplay=true", StringComparison.OrdinalIgnoreCase))
                            {
                                noDisplay = true;
                            }
                        }

                        // Skip non-Application types and hidden entries
                        if (type != null && type != "Application") continue;
                        if (noDisplay) continue;

                        if (exec != null)
                        {
                            // Extract binary name: strip path prefix, get first token
                            var binary = Path.GetFileName(exec.Split(' ')[0]);
                            if (!string.IsNullOrEmpty(binary) && !_execToDesktopId.ContainsKey(binary))
                            {
                                _execToDesktopId[binary] = desktopId;
                            }
                        }
                    }
                    catch
                    {
                        // Skip unreadable .desktop files
                    }
                }
            }
        }

        private bool PollRunningApps()
        {
            try
            {
                var current = ScanProcesses();
                if (!current.SetEquals(_runningApps))
                {
                    _runningApps = current;
                    RunningAppsChanged?.Invoke(new HashSet<string>(current));
                }
            }
            catch
            {
                // Ignore scan errors
            }

            return true; // Keep polling
        }

        private HashSet<string> ScanProcesses()
        {
            var result = new HashSet<string>();

            if (!Directory.Exists("/proc")) return result;

            foreach (var pidDir in Directory.GetDirectories("/proc"))
            {
                var dirName = Path.GetFileName(pidDir);
                if (!int.TryParse(dirName, out _)) continue;

                try
                {
                    // Read /proc/<pid>/comm for process name
                    var commPath = Path.Combine(pidDir, "comm");
                    if (File.Exists(commPath))
                    {
                        var comm = File.ReadAllText(commPath).Trim();
                        if (_backgroundProcesses.Contains(comm)) continue;
                        if (_execToDesktopId.TryGetValue(comm, out var desktopId))
                        {
                            result.Add(desktopId);
                            continue;
                        }
                    }

                    // Also try /proc/<pid>/cmdline for more accurate matching
                    var cmdlinePath = Path.Combine(pidDir, "cmdline");
                    if (File.Exists(cmdlinePath))
                    {
                        var cmdline = File.ReadAllText(cmdlinePath);
                        if (string.IsNullOrEmpty(cmdline)) continue;

                        // cmdline is null-separated; get first arg (the binary)
                        var firstArg = cmdline.Split('\0')[0];
                        var binary = Path.GetFileName(firstArg);
                        if (!string.IsNullOrEmpty(binary) && _execToDesktopId.TryGetValue(binary, out var desktopId2))
                        {
                            result.Add(desktopId2);
                        }
                    }
                }
                catch
                {
                    // Process may have exited; skip
                }
            }

            return result;
        }
    }
}
