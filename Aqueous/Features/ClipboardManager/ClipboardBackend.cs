using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

namespace Aqueous.Features.ClipboardManager
{
    public static class ClipboardBackend
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

        private static async Task<string> RunCommandWithInput(string command, string args, string input)
        {
            var psi = new ProcessStartInfo
            {
                FileName = command,
                Arguments = args,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            using var process = Process.Start(psi);
            if (process == null) return "";

            await process.StandardInput.WriteAsync(input);
            process.StandardInput.Close();

            var output = await process.StandardOutput.ReadToEndAsync();
            await process.WaitForExitAsync();
            return output;
        }

        public static async Task<string> GetCurrentClipboardAsync()
        {
            try
            {
                return (await RunCommand("wl-paste", "--no-newline")).TrimEnd();
            }
            catch
            {
                return "";
            }
        }

        public static async Task<List<ClipboardEntry>> GetClipboardHistoryAsync(int limit = 50)
        {
            var entries = new List<ClipboardEntry>();
            try
            {
                var output = await RunCommand("cliphist", "list");
                if (string.IsNullOrWhiteSpace(output)) return entries;

                var lines = output.Split('\n', StringSplitOptions.RemoveEmptyEntries);
                var count = 0;
                foreach (var line in lines)
                {
                    if (count >= limit) break;

                    var tabIndex = line.IndexOf('\t');
                    if (tabIndex < 0) continue;

                    var id = line[..tabIndex].Trim();
                    var content = line[(tabIndex + 1)..];
                    var isImage = content.StartsWith("[[ binary data", StringComparison.Ordinal);

                    entries.Add(new ClipboardEntry(id, content, isImage));
                    count++;
                }
            }
            catch
            {
                // cliphist unavailable
            }

            return entries;
        }

        public static async Task SetClipboardAsync(string content)
        {
            try
            {
                await RunCommandWithInput("wl-copy", "", content);
            }
            catch
            {
                // wl-copy unavailable
            }
        }

        public static async Task PasteEntryAsync(string id)
        {
            try
            {
                var psiDecode = new ProcessStartInfo
                {
                    FileName = "cliphist",
                    Arguments = "decode",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    RedirectStandardInput = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                var psiCopy = new ProcessStartInfo
                {
                    FileName = "wl-copy",
                    RedirectStandardInput = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using var decode = Process.Start(psiDecode);
                if (decode == null) return;

                await decode.StandardInput.WriteAsync(id);
                decode.StandardInput.Close();

                using var ms = new MemoryStream();
                await decode.StandardOutput.BaseStream.CopyToAsync(ms);
                await decode.WaitForExitAsync();
                var decoded = ms.ToArray();

                using var copy = Process.Start(psiCopy);
                if (copy == null) return;

                await copy.StandardInput.BaseStream.WriteAsync(decoded);
                copy.StandardInput.Close();
                await copy.WaitForExitAsync();
            }
            catch
            {
                // Silently fail
            }
        }

        public static async Task DeleteEntryAsync(string id)
        {
            try
            {
                await RunCommandWithInput("cliphist", "delete", id);
            }
            catch
            {
                // Silently fail
            }
        }

        public static async Task ClearHistoryAsync()
        {
            try
            {
                await RunCommand("cliphist", "wipe");
            }
            catch
            {
                // Silently fail
            }
        }

        public static async Task<string> GetMimeTypeAsync()
        {
            try
            {
                return (await RunCommand("wl-paste", "--list-types")).Trim();
            }
            catch
            {
                return "";
            }
        }
    }

    public record ClipboardEntry(string Id, string Content, bool IsImage);
}
