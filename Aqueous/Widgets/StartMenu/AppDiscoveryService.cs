using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Aqueous.Features.AppLauncher;

namespace Aqueous.Widgets.StartMenu;

public static class AppDiscoveryService
{
    private static readonly Dictionary<string, string> CategoryDisplayNames = new()
    {
        { "AudioVideo", "Multimedia" },
        { "Audio", "Multimedia" },
        { "Video", "Multimedia" },
        { "Development", "Development" },
        { "Education", "Education" },
        { "Game", "Games" },
        { "Graphics", "Graphics" },
        { "Network", "Internet" },
        { "Office", "Office" },
        { "Science", "Science" },
        { "Settings", "Settings" },
        { "System", "System" },
        { "Utility", "Utilities" },
    };

    public record CategorizedEntry(string Name, string Exec, string Icon, string Comment, List<string> Categories);

    private static List<CategorizedEntry>? _entries;

    public static List<CategorizedEntry> GetEntries()
    {
        _entries ??= ParseAllEntries();
        return _entries;
    }

    public static void Refresh()
    {
        _entries = ParseAllEntries();
    }

    public static Dictionary<string, List<CategorizedEntry>> GetByCategory()
    {
        var result = new Dictionary<string, List<CategorizedEntry>>();
        foreach (var entry in GetEntries())
        {
            var mapped = entry.Categories
                .Where(c => CategoryDisplayNames.ContainsKey(c))
                .Select(c => CategoryDisplayNames[c])
                .Distinct()
                .ToList();

            if (mapped.Count == 0)
                mapped.Add("Other");

            foreach (var cat in mapped)
            {
                if (!result.ContainsKey(cat))
                    result[cat] = new List<CategorizedEntry>();
                result[cat].Add(entry);
            }
        }

        return result.OrderBy(kv => kv.Key).ToDictionary(kv => kv.Key, kv => kv.Value.OrderBy(e => e.Name).ToList());
    }

    public static List<CategorizedEntry> Search(string query)
    {
        if (string.IsNullOrWhiteSpace(query))
            return GetEntries();

        var lower = query.ToLowerInvariant();
        return GetEntries()
            .Select(e => new { Entry = e, Score = ScoreEntry(e, lower) })
            .Where(x => x.Score > 0)
            .OrderByDescending(x => x.Score)
            .Select(x => x.Entry)
            .ToList();
    }

    private static int ScoreEntry(CategorizedEntry entry, string query)
    {
        var name = entry.Name.ToLowerInvariant();
        var comment = entry.Comment.ToLowerInvariant();

        if (name == query) return 100;
        if (name.StartsWith(query)) return 80;
        if (name.Contains(query)) return 60;
        if (comment.Contains(query)) return 30;
        return 0;
    }

    private static List<CategorizedEntry> ParseAllEntries()
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
        var entries = new List<CategorizedEntry>();

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

    private static CategorizedEntry? ParseDesktopFile(string path)
    {
        string? name = null, exec = null, icon = null, comment = null, categories = null;
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
                    break;
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
                case "Categories": categories = value; break;
                case "NoDisplay": noDisplay = value.Equals("true", StringComparison.OrdinalIgnoreCase); break;
                case "Hidden": hidden = value.Equals("true", StringComparison.OrdinalIgnoreCase); break;
            }
        }

        if (name == null || exec == null || noDisplay || hidden)
            return null;

        var cats = (categories ?? "")
            .Split(';', StringSplitOptions.RemoveEmptyEntries)
            .Select(c => c.Trim())
            .ToList();

        return new CategorizedEntry(name, exec, icon ?? "", comment ?? "", cats);
    }
}
