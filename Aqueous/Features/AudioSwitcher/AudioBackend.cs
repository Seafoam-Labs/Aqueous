using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text.Json;
using System.Threading.Tasks;

namespace Aqueous.Features.AudioSwitcher
{
    public static class AudioBackend
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
            return output;
        }

        private static async Task<(string defaultSink, string defaultSource)> GetDefaults()
        {
            var json = await RunCommand("pactl", "-f json info");
            if (string.IsNullOrWhiteSpace(json))
                return ("", "");

            try
            {
                var info = JsonSerializer.Deserialize(json, AudioJsonContext.Default.PactlServerInfo);
                return (info?.DefaultSinkName ?? "", info?.DefaultSourceName ?? "");
            }
            catch
            {
                return ("", "");
            }
        }

        public static async Task<List<AudioDevice>> ListSinks()
        {
            var devices = new List<AudioDevice>();
            var json = await RunCommand("pactl", "-f json list sinks");
            if (string.IsNullOrWhiteSpace(json)) return devices;

            try
            {
                var (defaultSink, _) = await GetDefaults();
                var sinks = JsonSerializer.Deserialize(json, AudioJsonContext.Default.PactlSinkArray);
                if (sinks == null) return devices;

                foreach (var s in sinks)
                {
                    devices.Add(new AudioDevice(
                        s.Index,
                        s.Name,
                        s.Description,
                        string.Equals(s.Name, defaultSink, StringComparison.Ordinal),
                        AudioDeviceType.Sink
                    ));
                }
            }
            catch
            {
                // Silently fail if pactl is unavailable or output is unexpected
            }

            return devices;
        }

        public static async Task<List<AudioDevice>> ListSources()
        {
            var devices = new List<AudioDevice>();
            var json = await RunCommand("pactl", "-f json list sources");
            if (string.IsNullOrWhiteSpace(json)) return devices;

            try
            {
                var (_, defaultSource) = await GetDefaults();
                var sources = JsonSerializer.Deserialize(json, AudioJsonContext.Default.PactlSourceArray);
                if (sources == null) return devices;

                foreach (var s in sources)
                {
                    // Skip monitor sources (they mirror sinks)
                    if (s.Name.Contains(".monitor", StringComparison.Ordinal))
                        continue;

                    devices.Add(new AudioDevice(
                        s.Index,
                        s.Name,
                        s.Description,
                        string.Equals(s.Name, defaultSource, StringComparison.Ordinal),
                        AudioDeviceType.Source
                    ));
                }
            }
            catch
            {
                // Silently fail
            }

            return devices;
        }

        public static async Task SetDefaultSink(string name)
        {
            await RunCommand("pactl", $"set-default-sink {name}");
        }

        public static async Task SetDefaultSource(string name)
        {
            await RunCommand("pactl", $"set-default-source {name}");
        }
    }
}
