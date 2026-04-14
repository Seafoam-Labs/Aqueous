using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace Aqueous.Features.Settings
{
    public class WayfireConfigService
    {
        private static readonly string WayfireIniPath =
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".config", "wayfire.ini");

        private static WayfireConfigService? _instance;
        public static WayfireConfigService Instance => _instance ??= new WayfireConfigService();

        private List<string> _lines = new();
        private bool _loaded;

        public void Load()
        {
            try
            {
                if (File.Exists(WayfireIniPath))
                    _lines = new List<string>(File.ReadAllLines(WayfireIniPath));
                else
                    _lines = new List<string>();
                _loaded = true;
            }
            catch
            {
                _lines = new List<string>();
                _loaded = true;
            }
        }

        public void Save()
        {
            try
            {
                File.WriteAllLines(WayfireIniPath, _lines);
            }
            catch
            {
                // Ignore save errors
            }
        }

        private void EnsureLoaded()
        {
            if (!_loaded) Load();
        }

        public string GetString(string section, string key, string defaultValue = "")
        {
            EnsureLoaded();
            var idx = FindKeyInSection(section, key);
            return idx >= 0 ? GetValue(_lines[idx]) : defaultValue;
        }

        public void SetString(string section, string key, string value)
        {
            EnsureLoaded();
            var idx = FindKeyInSection(section, key);
            if (idx >= 0)
                _lines[idx] = $"{key} = {value}";
            else
                InsertInSection(section, $"{key} = {value}");
        }

        public int GetInt(string section, string key, int defaultValue = 0)
        {
            var str = GetString(section, key, "");
            return int.TryParse(str, out var val) ? val : defaultValue;
        }

        public void SetInt(string section, string key, int value)
        {
            SetString(section, key, value.ToString());
        }

        public float GetFloat(string section, string key, float defaultValue = 0f)
        {
            var str = GetString(section, key, "");
            return float.TryParse(str, System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture, out var val) ? val : defaultValue;
        }

        public void SetFloat(string section, string key, float value)
        {
            SetString(section, key, value.ToString("F6", System.Globalization.CultureInfo.InvariantCulture));
        }

        public bool GetBool(string section, string key, bool defaultValue = false)
        {
            var str = GetString(section, key, "").ToLowerInvariant();
            return str switch
            {
                "true" => true,
                "false" => false,
                _ => defaultValue,
            };
        }

        public void SetBool(string section, string key, bool value)
        {
            SetString(section, key, value ? "true" : "false");
        }

        public string GetColor(string section, string key, string defaultValue = "#000000FF")
        {
            var str = GetString(section, key, defaultValue);
            return str.Replace("\\#", "#");
        }

        public void SetColor(string section, string key, string value)
        {
            SetString(section, key, "\\" + value);
        }

        public string GetKeybind(string section, string key, string defaultValue = "none")
        {
            return GetString(section, key, defaultValue);
        }

        public void SetKeybind(string section, string key, string value)
        {
            SetString(section, key, value);
        }

        public string GetDuration(string section, string key, string defaultValue = "0ms linear")
        {
            return GetString(section, key, defaultValue);
        }

        public void SetDuration(string section, string key, string value)
        {
            SetString(section, key, value);
        }

        public int GetDurationMs(string section, string key, int defaultValue = 0)
        {
            var str = GetString(section, key, "");
            if (string.IsNullOrEmpty(str)) return defaultValue;
            var parts = str.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length > 0 && parts[0].EndsWith("ms"))
            {
                if (int.TryParse(parts[0].AsSpan(0, parts[0].Length - 2), out var ms))
                    return ms;
            }
            return defaultValue;
        }

        public string GetDurationCurve(string section, string key, string defaultValue = "linear")
        {
            var str = GetString(section, key, "");
            if (string.IsNullOrEmpty(str)) return defaultValue;
            var parts = str.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            return parts.Length > 1 ? parts[1] : defaultValue;
        }

        public void SetDurationMs(string section, string key, int ms, string? curve = null)
        {
            curve ??= GetDurationCurve(section, key);
            SetString(section, key, $"{ms}ms {curve}");
        }

        public void RemoveKey(string section, string key)
        {
            EnsureLoaded();
            var idx = FindKeyInSection(section, key);
            if (idx >= 0)
                _lines.RemoveAt(idx);
        }

        /// <summary>
        /// Ensures the given bindings exist in the specified section.
        /// Existing keys are never overwritten.
        /// </summary>
        public void EnsureBindings(Dictionary<string, string> bindings, string section = "command")
        {
            EnsureLoaded();
            bool changed = false;
            foreach (var (key, value) in bindings)
            {
                if (FindKeyInSection(section, key) < 0)
                {
                    InsertInSection(section, $"{key} = {value}");
                    changed = true;
                }
            }
            if (changed)
                Save();
        }

        private static string ResolveScreenshotBinary()
        {
            var pathDirs = Environment.GetEnvironmentVariable("PATH")?.Split(':') ?? [];
            foreach (var dir in pathDirs)
            {
                var candidate = Path.Combine(dir, "aqueous-screenshot");
                if (File.Exists(candidate))
                    return "aqueous-screenshot";
            }

            var baseDir = AppContext.BaseDirectory;
            var projectRoot = Path.GetFullPath(Path.Combine(baseDir, "..", "..", "..", ".."));
            var screenshotBin = Path.Combine(projectRoot, "AqueousScreenshot", "bin", "Debug", "net10.0", "AqueousScreenshot");

            if (File.Exists(screenshotBin))
                return screenshotBin;

            return "aqueous-screenshot";
        }

        private static Dictionary<string, string> GetScreenshotBindings()
        {
            var bin = ResolveScreenshotBinary();
            return new Dictionary<string, string>
            {
                ["binding_screenshot"] = "KEY_SYSRQ",
                ["command_screenshot"] = $"{bin} --fullscreen --clipboard",
                ["binding_screenshot_region"] = "<shift> KEY_SYSRQ",
                ["command_screenshot_region"] = $"{bin} --region --clipboard",
                ["binding_screenshot_window"] = "<alt> KEY_SYSRQ",
                ["command_screenshot_window"] = $"{bin} --active-window --clipboard",
                ["binding_screenshot_ui"] = "<super> KEY_SYSRQ",
                ["command_screenshot_ui"] = bin,
            };
        }

        public void EnsureBrightnessBindings()
        {
            var bindings = new Dictionary<string, string>
            {
                ["binding_brightness_up"] = "KEY_BRIGHTNESSUP",
                ["command_brightness_up"] = "aqueous-brightness up",
                ["binding_brightness_down"] = "KEY_BRIGHTNESSDOWN",
                ["command_brightness_down"] = "aqueous-brightness down",
            };
            EnsureBindings(bindings);
        }

        public void EnsureScreenshotBindings()
        {
            var bindings = GetScreenshotBindings();
            EnsureLoaded();
            bool changed = false;

            foreach (var (key, value) in bindings)
            {
                var idx = FindKeyInSection("command", key);
                if (idx < 0)
                {
                    InsertInSection("command", $"{key} = {value}");
                    changed = true;
                }
                else if (key.StartsWith("command_"))
                {
                    var existing = GetValue(_lines[idx]);
                    if (existing.StartsWith("aqueous-screenshot") && value.StartsWith("/"))
                    {
                        _lines[idx] = $"{key} = {value}";
                        changed = true;
                    }
                }
            }

            if (changed)
                Save();
        }

        // Internal helpers

        private int FindSectionStart(string section)
        {
            for (int i = 0; i < _lines.Count; i++)
            {
                if (_lines[i].Trim() == $"[{section}]")
                    return i;
            }
            return -1;
        }

        private int FindKeyInSection(string section, string key)
        {
            int sectionStart = FindSectionStart(section);
            if (sectionStart < 0) return -1;

            int lastFound = -1;
            for (int i = sectionStart + 1; i < _lines.Count; i++)
            {
                var trimmed = _lines[i].Trim();
                if (trimmed.StartsWith('[') && trimmed.EndsWith(']'))
                    break;
                if (trimmed.StartsWith(key + " =") || trimmed.StartsWith(key + "="))
                    lastFound = i;
            }
            return lastFound;
        }

        private static string GetValue(string line)
        {
            var idx = line.IndexOf('=');
            return idx >= 0 ? line.Substring(idx + 1).Trim() : "";
        }

        private void InsertInSection(string section, string entry)
        {
            int sectionStart = FindSectionStart(section);
            if (sectionStart < 0)
            {
                _lines.Add("");
                _lines.Add($"[{section}]");
                _lines.Add(entry);
                return;
            }

            int insertAt = sectionStart + 1;
            for (int i = sectionStart + 1; i < _lines.Count; i++)
            {
                var trimmed = _lines[i].Trim();
                if (trimmed.StartsWith('[') && trimmed.EndsWith(']'))
                    break;
                insertAt = i + 1;
            }
            _lines.Insert(insertAt, entry);
        }
    }
}
