using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using Gtk;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class DisplayPage
    {
        private static string OutputSection => $"output:{DetectedOutputName}";
        private static string DetectedOutputName = DetectOutputName();

        private static Gtk.DropDown? _resolutionDropdown;
        private static Gtk.DropDown? _refreshDropdown;
        private static string[] _currentResolutions = [];
        private static string[] _currentRefreshRates = [];

        public static Gtk.Box Create(SettingsStore store)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            // --- Resolution & Refresh Rate Section ---
            page.Append(SettingsWidgets.SectionTitle("Resolution & Refresh Rate"));

            var detectedModes = DetectAvailableModes();

            if (detectedModes.Count > 0)
            {
                page.Append(CreateResolutionRow(detectedModes));
                page.Append(CreateRefreshRateRow(detectedModes));
                page.Append(CreateCurrentModeInfo());
                page.Append(CreateApplyResolutionButton());
            }
            else
            {
                // No detected modes — show current value + free-text entry only
                page.Append(CreateCurrentModeInfo());
                page.Append(SettingsWidgets.Entry("Mode (auto or WxH@Hz)",
                    OutputSection, "mode", "auto"));

                var hint = Gtk.Label.New(
                    "Could not detect available modes via wlr-randr.\n" +
                    "Enter a mode manually, e.g. 1920x1080@60.000, or auto.");
                hint.AddCssClass("hdr-info");
                hint.Halign = Align.Start;
                hint.Wrap = true;
                hint.MarginTop = 4;
                page.Append(hint);
            }

            // --- Separator ---
            var separator = Gtk.Separator.New(Orientation.Horizontal);
            separator.MarginTop = 16;
            separator.MarginBottom = 8;
            page.Append(separator);

            // --- HDR Section ---
            var hdrContent = HdrPage.Create(store);
            page.Append(hdrContent);

            return page;
        }

        private static Gtk.Box CreateCurrentModeInfo()
        {
            var box = Gtk.Box.New(Orientation.Vertical, 4);
            box.MarginTop = 8;

            var config = WayfireConfigService.Instance;
            var currentMode = config.GetString(OutputSection, "mode", "auto");

            var info = Gtk.Label.New($"Current wayfire.ini mode: {currentMode}");
            info.AddCssClass("hdr-info");
            info.Halign = Align.Start;
            box.Append(info);

            var warning = Gtk.Label.New(
                "⚠ Changing resolution requires a compositor restart to take effect.");
            warning.AddCssClass("hdr-warning");
            warning.Halign = Align.Start;
            warning.Wrap = true;
            box.Append(warning);

            return box;
        }

        private static Gtk.Box CreateResolutionRow(List<DisplayMode> detectedModes)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var label = Gtk.Label.New("Resolution");
            label.Hexpand = true;
            label.Halign = Align.Start;
            row.Append(label);

            // Build resolution list purely from detected modes
            _currentResolutions = detectedModes
                .Select(m => $"{m.Width}x{m.Height}")
                .Distinct()
                .Prepend("auto")
                .ToArray();

            var stringList = Gtk.StringList.New(_currentResolutions);
            _resolutionDropdown = Gtk.DropDown.New(stringList, null);

            // Select current value
            var config = WayfireConfigService.Instance;
            var currentMode = config.GetString(OutputSection, "mode", "auto");
            var currentRes = "auto";
            if (currentMode != "auto" && currentMode.Contains('x'))
            {
                var atIdx = currentMode.IndexOf('@');
                currentRes = atIdx > 0 ? currentMode[..atIdx] : currentMode;
            }

            for (uint i = 0; i < _currentResolutions.Length; i++)
            {
                if (_currentResolutions[i] == currentRes)
                {
                    _resolutionDropdown.Selected = i;
                    break;
                }
            }

            row.Append(_resolutionDropdown);
            return row;
        }

        private static Gtk.Box CreateRefreshRateRow(List<DisplayMode> detectedModes)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var label = Gtk.Label.New("Refresh rate (Hz)");
            label.Hexpand = true;
            label.Halign = Align.Start;
            row.Append(label);

            // Build refresh rate list purely from detected modes
            _currentRefreshRates = detectedModes
                .Select(m => m.Refresh)
                .Distinct()
                .OrderByDescending(r =>
                    double.TryParse(r, NumberStyles.Float,
                        CultureInfo.InvariantCulture, out var v) ? v : 0)
                .ToArray();

            var stringList = Gtk.StringList.New(_currentRefreshRates);
            _refreshDropdown = Gtk.DropDown.New(stringList, null);

            // Select current value
            var config = WayfireConfigService.Instance;
            var currentMode = config.GetString(OutputSection, "mode", "auto");
            if (currentMode.Contains('@'))
            {
                var currentRefresh = currentMode[(currentMode.IndexOf('@') + 1)..];
                for (uint i = 0; i < _currentRefreshRates.Length; i++)
                {
                    if (_currentRefreshRates[i] == currentRefresh)
                    {
                        _refreshDropdown.Selected = i;
                        break;
                    }
                }
            }

            row.Append(_refreshDropdown);
            return row;
        }

        private static Gtk.Box CreateApplyResolutionButton()
        {
            var box = Gtk.Box.New(Orientation.Horizontal, 0);
            box.MarginTop = 12;

            var btn = Gtk.Button.NewWithLabel("Apply Display Settings");
            btn.AddCssClass("settings-save-btn");
            btn.OnClicked += (_, _) => ApplyResolutionSettings();
            box.Append(btn);

            return box;
        }

        private static void ApplyResolutionSettings()
        {
            try
            {
                var config = WayfireConfigService.Instance;

                if (_resolutionDropdown == null || _refreshDropdown == null)
                    return;

                var resModel = _resolutionDropdown.GetModel() as Gtk.StringList;
                var refreshModel = _refreshDropdown.GetModel() as Gtk.StringList;

                var resolution = resModel?.GetString(_resolutionDropdown.Selected) ?? "auto";
                var refresh = refreshModel?.GetString(_refreshDropdown.Selected) ?? "";

                string mode;
                if (resolution == "auto")
                {
                    mode = "auto";
                }
                else
                {
                    mode = string.IsNullOrEmpty(refresh)
                        ? resolution
                        : $"{resolution}@{refresh}";
                }

                config.SetString(OutputSection, "mode", mode);
                config.Save();
            }
            catch
            {
                // Ignore errors
            }
        }

        /// <summary>
        /// Parses wlr-randr output to detect available display modes.
        /// Returns empty list if wlr-randr is unavailable or fails.
        /// </summary>
        private static List<DisplayMode> DetectAvailableModes()
        {
            var modes = new List<DisplayMode>();
            try
            {
                var psi = new ProcessStartInfo("wlr-randr")
                {
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };
                using var proc = Process.Start(psi);
                if (proc == null) return modes;

                var output = proc.StandardOutput.ReadToEnd();
                proc.WaitForExit(3000);

                if (proc.ExitCode != 0) return modes;

                foreach (var line in output.Split('\n'))
                {
                    var trimmed = line.Trim();
                    if (!trimmed.Contains("px,") || !trimmed.Contains("Hz"))
                        continue;

                    var parts = trimmed.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                    if (parts.Length < 3) continue;

                    var resPart = parts[0];
                    var xIdx = resPart.IndexOf('x');
                    if (xIdx <= 0) continue;

                    var width = resPart[..xIdx];
                    var height = resPart[(xIdx + 1)..];

                    for (int i = 1; i < parts.Length; i++)
                    {
                        if (parts[i] == "Hz" && i > 0)
                        {
                            var refreshStr = parts[i - 1].TrimEnd(',');
                            if (double.TryParse(refreshStr, NumberStyles.Float,
                                    CultureInfo.InvariantCulture, out var refreshVal))
                            {
                                modes.Add(new DisplayMode
                                {
                                    Width = width,
                                    Height = height,
                                    Refresh = refreshVal.ToString("F3",
                                        CultureInfo.InvariantCulture)
                                });
                            }
                            break;
                        }
                    }
                }
            }
            catch
            {
                // wlr-randr not available
            }

            return modes;
        }

        /// <summary>
        /// Detects the primary output name from wlr-randr (e.g. eDP-1, HDMI-A-1).
        /// Falls back to empty string if detection fails, resulting in section "output:".
        /// </summary>
        private static string DetectOutputName()
        {
            try
            {
                var psi = new ProcessStartInfo("wlr-randr")
                {
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };
                using var proc = Process.Start(psi);
                if (proc == null) return "";

                var output = proc.StandardOutput.ReadToEnd();
                proc.WaitForExit(3000);

                if (proc.ExitCode != 0) return "";

                foreach (var line in output.Split('\n'))
                {
                    // Output names are non-indented lines, e.g. "eDP-1 \"BOE 0x0BCA\" (16 modes)"
                    if (string.IsNullOrWhiteSpace(line)) continue;
                    if (line.StartsWith(' ') || line.StartsWith('\t')) continue;

                    var name = line.Split(' ', StringSplitOptions.RemoveEmptyEntries)[0];
                    if (!string.IsNullOrEmpty(name))
                        return name;
                }
            }
            catch
            {
                // wlr-randr not available
            }

            return "";
        }

        private struct DisplayMode
        {
            public string Width;
            public string Height;
            public string Refresh;
        }
    }
}
