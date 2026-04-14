using System;
using System.Diagnostics;
using System.Threading.Tasks;

namespace Aqueous.Features.Brightness
{
    public static class BrightnessBackend
    {
        private static async Task<string> RunCommand(string command, string args)
        {
            var psi = new ProcessStartInfo
            {
                FileName = command,
                Arguments = args,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            using var process = Process.Start(psi);
            if (process == null) return "";

            var output = await process.StandardOutput.ReadToEndAsync();
            await process.WaitForExitAsync();
            return output.Trim();
        }

        public static async Task<int> GetBrightnessAsync()
        {
            var output = await RunCommand("brightnessctl", "get");
            return int.TryParse(output, out var val) ? val : 0;
        }

        public static async Task<int> GetMaxBrightnessAsync()
        {
            var output = await RunCommand("brightnessctl", "max");
            return int.TryParse(output, out var val) ? val : 1;
        }

        public static async Task<int> GetBrightnessPercentAsync()
        {
            var current = await GetBrightnessAsync();
            var max = await GetMaxBrightnessAsync();
            if (max <= 0) return 0;
            return (int)Math.Round(current * 100.0 / max);
        }

        public static async Task SetBrightnessAsync(int percent)
        {
            percent = Math.Clamp(percent, 0, 100);
            await RunCommand("brightnessctl", $"set {percent}%");
        }

        public static async Task SetBrightnessAsync(string value)
        {
            await RunCommand("brightnessctl", $"set {value}");
        }

        public static async Task<bool> IsAvailableAsync()
        {
            var output = await RunCommand("brightnessctl", "-l");
            return !string.IsNullOrWhiteSpace(output);
        }

        public static async Task<string> GetDeviceNameAsync()
        {
            var output = await RunCommand("brightnessctl", "-l");
            if (string.IsNullOrWhiteSpace(output)) return "";
            // First line typically contains device name
            var firstLine = output.Split('\n')[0];
            return firstLine.Trim();
        }
    }
}
