using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;

namespace Aqueous.Features.Settings
{
    /// <summary>
    /// Manages display output persistence across Wayfire restarts.
    /// On startup, validates saved per-output modes against available hardware modes
    /// and applies them live via wlr-randr. Also provides methods to apply and persist
    /// resolution changes at runtime.
    /// </summary>
    public class DisplaySettingsManager
    {
        private static DisplaySettingsManager? _instance;
        public static DisplaySettingsManager Instance => _instance ??= new DisplaySettingsManager();

        /// <summary>
        /// Called on application startup. For each connected output, checks if a
        /// per-output section exists in wayfire.ini with a saved mode. If the saved
        /// mode is still available, applies it via wlr-randr. If not, falls back to auto.
        /// </summary>
        public void ValidateAndApplySavedModes()
        {
            try
            {
                var outputs = DetectAllOutputs();
                var config = WayfireConfigService.Instance;

                foreach (var output in outputs)
                {
                    var section = $"output:{output.Name}";
                    var savedMode = config.GetString(section, "mode", "");

                    if (string.IsNullOrEmpty(savedMode) || savedMode == "auto")
                        continue;

                    // Check if the saved mode is still available
                    if (IsModeAvailable(output, savedMode))
                    {
                        ApplyModeViaWlrRandr(output.Name, savedMode);
                    }
                    else
                    {
                        // Saved mode no longer available — fall back to auto
                        config.SetString(section, "mode", "auto");
                        config.Save();
                    }
                }
            }
            catch
            {
                // Silently handle errors during startup validation
            }
        }

        /// <summary>
        /// Applies a display mode change both live (via wlr-randr) and persists it to wayfire.ini.
        /// </summary>
        public void ApplyAndPersist(string outputName, string mode)
        {
            var config = WayfireConfigService.Instance;
            var section = $"output:{outputName}";

            // Apply live via wlr-randr
            ApplyModeViaWlrRandr(outputName, mode);

            // Persist to wayfire.ini
            config.SetString(section, "mode", mode);
            config.Save();
        }

        /// <summary>
        /// Applies a mode to an output using wlr-randr.
        /// Mode format: "auto", "WxH", or "WxH@refresh"
        /// wlr-randr expects: --output NAME --mode WxH@refresh or --mode WxH
        /// </summary>
        public static bool ApplyModeViaWlrRandr(string outputName, string mode)
        {
            try
            {
                if (mode == "auto")
                    return ApplyAutoMode(outputName);

                var psi = new ProcessStartInfo("wlr-randr")
                {
                    Arguments = $"--output {outputName} --mode {mode}",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using var proc = Process.Start(psi);
                if (proc == null) return false;

                var stderr = proc.StandardError.ReadToEnd();
                var stdout = proc.StandardOutput.ReadToEnd();
                proc.WaitForExit(5000);

                if (proc.ExitCode != 0)
                {
                    Console.Error.WriteLine($"[Display] wlr-randr failed (exit {proc.ExitCode}): {stderr}");
                    return false;
                }

                return true;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[Display] Failed to run wlr-randr: {ex.Message}");
                return false;
            }
        }

        private static bool ApplyAutoMode(string outputName)
        {
            try
            {
                // Get the preferred (first listed) mode for this output
                var outputs = DetectAllOutputs();
                var output = outputs.FirstOrDefault(o => o.Name == outputName);
                if (output.Name == null || output.AvailableModes.Count == 0)
                    return false;

                // The first mode is typically the preferred/native mode
                var preferredMode = output.AvailableModes[0];
                var modeStr = $"{preferredMode.Width}x{preferredMode.Height}@{preferredMode.Refresh}";

                var psi = new ProcessStartInfo("wlr-randr")
                {
                    Arguments = $"--output {outputName} --mode {modeStr}",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using var proc = Process.Start(psi);
                if (proc == null) return false;

                proc.WaitForExit(5000);
                return proc.ExitCode == 0;
            }
            catch
            {
                return false;
            }
        }

        /// <summary>
        /// Checks if a given mode string (e.g. "1920x1080@60.000") is available for the output.
        /// </summary>
        private static bool IsModeAvailable(OutputInfo output, string modeStr)
        {
            // Parse the mode string
            var atIdx = modeStr.IndexOf('@');
            string resPart;
            string? refreshPart = null;

            if (atIdx > 0)
            {
                resPart = modeStr[..atIdx];
                refreshPart = modeStr[(atIdx + 1)..];
            }
            else
            {
                resPart = modeStr;
            }

            var xIdx = resPart.IndexOf('x');
            if (xIdx <= 0) return false;

            var targetWidth = resPart[..xIdx];
            var targetHeight = resPart[(xIdx + 1)..];

            foreach (var mode in output.AvailableModes)
            {
                if (mode.Width != targetWidth || mode.Height != targetHeight)
                    continue;

                if (refreshPart == null)
                    return true; // Resolution matches, any refresh rate is fine

                // Extremely tight tolerance instead of 0.01 to avoid rounding to whole numbers 
                // while still handling negligible float inaccuracies like .000001
                if (double.TryParse(refreshPart, NumberStyles.Float, CultureInfo.InvariantCulture, out var targetRefresh) &&
                    double.TryParse(mode.Refresh, NumberStyles.Float, CultureInfo.InvariantCulture, out var availRefresh))
                {
                    if (Math.Abs(targetRefresh - availRefresh) < 0.001)
                        return true;
                }
            }

            return false;
        }

        /// <summary>
        /// Detects all connected outputs and their available modes via wlr-randr.
        /// </summary>
        private static List<OutputInfo> DetectAllOutputs()
        {
            var outputs = new List<OutputInfo>();
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
                if (proc == null) return outputs;

                var rawOutput = proc.StandardOutput.ReadToEnd();
                proc.WaitForExit(3000);

                if (proc.ExitCode != 0) return outputs;

                OutputInfo? current = null;

                foreach (var line in rawOutput.Split('\n'))
                {
                    if (string.IsNullOrWhiteSpace(line)) continue;

                    // Non-indented lines are output names
                    if (!line.StartsWith(' ') && !line.StartsWith('\t'))
                    {
                        if (current != null)
                            outputs.Add(current.Value);

                        var name = line.Split(' ', StringSplitOptions.RemoveEmptyEntries)[0];
                        current = new OutputInfo
                        {
                            Name = name,
                            AvailableModes = new List<ModeInfo>()
                        };
                        continue;
                    }

                    // Mode lines contain "px," and "Hz"
                    var trimmed = line.Trim();
                    if (current != null && trimmed.Contains("px,") && trimmed.Contains("Hz"))
                    {
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
                                if (!string.IsNullOrEmpty(refreshStr))
                                {
                                    current.Value.AvailableModes.Add(new ModeInfo
                                    {
                                        Width = width,
                                        Height = height,
                                        Refresh = refreshStr
                                    });
                                }
                                break;
                            }
                        }
                    }
                }

                if (current != null)
                    outputs.Add(current.Value);
            }
            catch
            {
                // wlr-randr not available
            }

            return outputs;
        }

        public struct OutputInfo
        {
            public string Name;
            public List<ModeInfo> AvailableModes;
        }

        public struct ModeInfo
        {
            public string Width;
            public string Height;
            public string Refresh;
        }
    }
}
