using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;

namespace Aqueous.Features.Autostart;

public static class XdgAutostartService
{
    public static void LaunchAll()
    {
        var desktopFiles = GetAutostartDesktopFiles();

        foreach (var file in desktopFiles)
        {
            try
            {
                // Skip KDE-related desktop files by filename
                var fileName = Path.GetFileName(file);
                if (IsKdeRelated(fileName))
                {
                    Console.WriteLine($"[Autostart] Skipping KDE entry: {fileName}");
                    continue;
                }

                var entry = ParseDesktopFile(file);
                if (entry == null) continue;
                if (entry.Hidden) continue;
                if (!ShouldShowInCurrentDesktop(entry)) continue;

                var exec = StripFieldCodes(entry.Exec);
                if (string.IsNullOrWhiteSpace(exec)) continue;

                Console.WriteLine($"[Autostart] Launching: {entry.Name} ({exec})");

                // Route autostart entries through the shared hardened spawner
                // so they inherit the correct Wayland env (WAYLAND_DISPLAY,
                // XDG_RUNTIME_DIR) and don't silently fall back to Xwayland,
                // which would prevent them from registering with river.
                Aqueous.Helpers.WaylandSpawn.Spawn(exec);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[Autostart] Failed to launch {file}: {ex.Message}");
            }
        }
    }

    private static List<string> GetAutostartDesktopFiles()
    {
        var dirs = new List<string>();

        // User directory takes priority
        var userDir = Path.Combine(
            Environment.GetEnvironmentVariable("XDG_CONFIG_HOME")
                ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config"),
            "autostart");
        if (Directory.Exists(userDir))
            dirs.Add(userDir);

        // System directories
        var xdgConfigDirs = Environment.GetEnvironmentVariable("XDG_CONFIG_DIRS") ?? "/etc/xdg";
        foreach (var dir in xdgConfigDirs.Split(':'))
        {
            var sysDir = Path.Combine(dir, "autostart");
            if (Directory.Exists(sysDir))
                dirs.Add(sysDir);
        }

        // Collect files; user entries override system entries (by filename)
        var seen = new HashSet<string>();
        var result = new List<string>();

        foreach (var dir in dirs)
        {
            foreach (var file in Directory.GetFiles(dir, "*.desktop"))
            {
                var name = Path.GetFileName(file);
                if (seen.Add(name)) // only add if not already seen (user wins)
                    result.Add(file);
            }
        }

        return result;
    }

    private static DesktopEntry? ParseDesktopFile(string path)
    {
        var entry = new DesktopEntry();
        bool inDesktopEntry = false;

        foreach (var rawLine in File.ReadLines(path))
        {
            var line = rawLine.Trim();

            if (line.StartsWith('['))
            {
                inDesktopEntry = line == "[Desktop Entry]";
                continue;
            }

            if (!inDesktopEntry) continue;

            var eqIndex = line.IndexOf('=');
            if (eqIndex < 0) continue;

            var key = line[..eqIndex].Trim();
            var value = line[(eqIndex + 1)..].Trim();

            switch (key)
            {
                case "Name": entry.Name = value; break;
                case "Exec": entry.Exec = value; break;
                case "Hidden": entry.Hidden = value.Equals("true", StringComparison.OrdinalIgnoreCase); break;
                case "Type": entry.Type = value; break;
                case "OnlyShowIn": entry.OnlyShowIn = value.Split(';', StringSplitOptions.RemoveEmptyEntries).ToList(); break;
                case "NotShowIn": entry.NotShowIn = value.Split(';', StringSplitOptions.RemoveEmptyEntries).ToList(); break;
                case "TryExec": entry.TryExec = value; break;
            }
        }

        // Must be type Application (or unset, defaults to Application)
        if (!string.IsNullOrEmpty(entry.Type) && entry.Type != "Application")
            return null;

        // If TryExec is set, check the binary exists
        if (!string.IsNullOrEmpty(entry.TryExec))
        {
            if (!File.Exists(entry.TryExec) && !ExistsOnPath(entry.TryExec))
                return null;
        }

        return string.IsNullOrEmpty(entry.Exec) ? null : entry;
    }

    private static bool ShouldShowInCurrentDesktop(DesktopEntry entry)
    {
        // Identify as "Aqueous" (and optionally "Wayfire")
        var currentDesktops = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "Aqueous", "Wayfire" };

        // Also respect $XDG_CURRENT_DESKTOP if set
        var envDesktops = Environment.GetEnvironmentVariable("XDG_CURRENT_DESKTOP");
        if (!string.IsNullOrEmpty(envDesktops))
        {
            currentDesktops.Clear();
            foreach (var d in envDesktops.Split(':'))
                currentDesktops.Add(d);
        }

        if (entry.OnlyShowIn.Count > 0)
            return entry.OnlyShowIn.Any(d => currentDesktops.Contains(d));

        if (entry.NotShowIn.Count > 0)
            return !entry.NotShowIn.Any(d => currentDesktops.Contains(d));

        return true;
    }

    /// <summary>
    /// Strip desktop entry field codes like %f, %F, %u, %U, etc.
    /// </summary>
    private static string StripFieldCodes(string exec)
    {
        return System.Text.RegularExpressions.Regex.Replace(exec, @"%[fFuUdDnNickvm]", "").Trim();
    }

    private static bool IsKdeRelated(string fileName)
    {
        var lower = fileName.ToLowerInvariant();
        return lower.StartsWith("org.kde.") ||
               lower.Contains("kde") ||
               lower.Contains("plasma") ||
               lower.Contains("kwallet") ||
               lower.Contains("kaccess") ||
               lower.Contains("kmix") ||
               lower.Contains("konqy") ||
               lower.Contains("baloo") ||
               lower.Contains("powerdevil") ||
               lower.Contains("kglobalaccel") ||
               lower.Contains("xembedsniproxy") ||
               lower.Contains("gmenudbusmenuproxy");
    }

    private static bool ExistsOnPath(string fileName)
    {
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        return path.Split(':').Any(dir => File.Exists(Path.Combine(dir, fileName)));
    }

    private class DesktopEntry
    {
        public string Name { get; set; } = "";
        public string Exec { get; set; } = "";
        public string Type { get; set; } = "";
        public string TryExec { get; set; } = "";
        public bool Hidden { get; set; }
        public List<string> OnlyShowIn { get; set; } = new();
        public List<string> NotShowIn { get; set; } = new();
    }
}
