using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace Aqueous.Features.AppLauncher
{
    public record DesktopEntry(string Name, string Exec, string Icon, string Comment)
    {
        // Pre-computed lowercase fields. Avoids ToLowerInvariant() allocation on every keystroke
        // across ~500 desktop entries (was ~10k string allocations per 10-char query).
        public string NameLower { get; } = Name.ToLowerInvariant();
        public string CommentLower { get; } = Comment.ToLowerInvariant();
    }

    public static class AppLauncherSearch
    {
        private static List<DesktopEntry>? _entries;

        public static List<DesktopEntry> GetEntries()
        {
            _entries ??= ParseAllEntries();
            return _entries;
        }

        public static void Refresh()
        {
            _entries = ParseAllEntries();
        }

        public static List<DesktopEntry> Search(string query)
        {
            if (string.IsNullOrWhiteSpace(query))
                return GetEntries().Take(8).ToList();

            var lower = query.ToLowerInvariant();
            return GetEntries()
                .Select(e => new { Entry = e, Score = ScoreEntry(e, lower) })
                .Where(x => x.Score > 0)
                .OrderByDescending(x => x.Score)
                .Take(8)
                .Select(x => x.Entry)
                .ToList();
        }

        private static int ScoreEntry(DesktopEntry entry, string query)
        {
            var name = entry.NameLower;
            var comment = entry.CommentLower;

            if (name == query) return 100;
            if (name.StartsWith(query)) return 80;
            if (name.Contains(query)) return 60;
            if (comment.Contains(query)) return 30;
            return 0;
        }

        public static string CleanExec(string exec)
        {
            var cleaned = exec;
            string[] codes = ["%f", "%F", "%u", "%U", "%d", "%D", "%n", "%N", "%i", "%c", "%k"];
            foreach (var code in codes)
                cleaned = cleaned.Replace(code, "");
            return cleaned.Trim();
        }

        private static List<DesktopEntry> ParseAllEntries()
        {
            var dirs = new List<string>
            {
                "/usr/share/applications",
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                    ".local", "share", "applications")
            };

            var xdgDataDirs = Environment.GetEnvironmentVariable("XDG_DATA_DIRS");
            if (!string.IsNullOrEmpty(xdgDataDirs))
            {
                foreach (var dir in xdgDataDirs.Split(':'))
                {
                    var appDir = Path.Combine(dir, "applications");
                    if (!dirs.Contains(appDir))
                        dirs.Add(appDir);
                }
            }

            var seen = new HashSet<string>();
            var entries = new List<DesktopEntry>();

            foreach (var dir in dirs)
            {
                if (!Directory.Exists(dir)) continue;
                foreach (var file in Directory.EnumerateFiles(dir, "*.desktop"))
                {
                    var fileName = Path.GetFileName(file);
                    if (!seen.Add(fileName)) continue;

                    var entry = ParseDesktopFile(file);
                    if (entry != null)
                        entries.Add(entry);
                }
            }

            return entries.OrderBy(e => e.Name).ToList();
        }

        private static DesktopEntry? ParseDesktopFile(string path)
        {
            string? name = null, exec = null, icon = null, comment = null;
            bool noDisplay = false, hidden = false;
            bool inDesktopEntry = false;

            foreach (var line in File.ReadLines(path))
            {
                var trimmed = line.Trim();
                if (trimmed.StartsWith('['))
                {
                    if (trimmed == "[Desktop Entry]")
                        inDesktopEntry = true;
                    else if (inDesktopEntry)
                        break; // Left the [Desktop Entry] section
                    continue;
                }

                if (!inDesktopEntry) continue;

                var eqIdx = trimmed.IndexOf('=');
                if (eqIdx < 0) continue;

                var key = trimmed.Substring(0, eqIdx).Trim();
                var value = trimmed.Substring(eqIdx + 1).Trim();

                switch (key)
                {
                    case "Name": name = value; break;
                    case "Exec": exec = value; break;
                    case "Icon": icon = value; break;
                    case "Comment": comment = value; break;
                    case "NoDisplay": noDisplay = value.Equals("true", StringComparison.OrdinalIgnoreCase); break;
                    case "Hidden": hidden = value.Equals("true", StringComparison.OrdinalIgnoreCase); break;
                }
            }

            if (name == null || exec == null || noDisplay || hidden)
                return null;

            return new DesktopEntry(name, exec, icon ?? "", comment ?? "");
        }
    }
}
