using System;
using System.Diagnostics;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace AqueousScreenshot
{
    public static class CaptureBackend
    {
        private static readonly string ScreenshotDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Pictures", "Screenshots");

        public static string GenerateFilePath()
        {
            Directory.CreateDirectory(ScreenshotDir);
            var timestamp = DateTime.Now.ToString("yyyy-MM-dd_HHmmss");
            return Path.Combine(ScreenshotDir, $"Screenshot_{timestamp}.png");
        }

        public static async Task<string?> CaptureFullscreen()
        {
            var path = GenerateFilePath();
            var result = await RunProcess("grim", path);
            return result ? path : null;
        }

        public static async Task<string?> CaptureRegion(int x, int y, int w, int h)
        {
            var path = GenerateFilePath();
            var result = await RunProcess("grim", $"-g \"{x},{y} {w}x{h}\" {path}");
            return result ? path : null;
        }

        public static async Task<string?> CaptureActiveWindow()
        {
            var geometry = await GetFocusedViewGeometry();
            if (geometry == null) return null;

            var (x, y, w, h) = geometry.Value;
            return await CaptureRegion(x, y, w, h);
        }

        public static async Task<string?> CaptureInteractiveRegion()
        {
            var path = GenerateFilePath();
            // Use slurp for interactive region selection, then grim
            var slurpResult = await RunProcessWithOutput("slurp");
            if (slurpResult == null) return null;

            var region = slurpResult.Trim();
            if (string.IsNullOrEmpty(region)) return null;

            var result = await RunProcess("grim", $"-g \"{region}\" {path}");
            return result ? path : null;
        }

        public static async Task<bool> CopyToClipboard(string filePath)
        {
            var psi = new ProcessStartInfo
            {
                FileName = "wl-copy",
                Arguments = "--type image/png",
                RedirectStandardInput = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            try
            {
                using var process = Process.Start(psi);
                if (process == null) return false;

                var bytes = await File.ReadAllBytesAsync(filePath);
                await process.StandardInput.BaseStream.WriteAsync(bytes);
                process.StandardInput.Close();
                await process.WaitForExitAsync();
                return process.ExitCode == 0;
            }
            catch
            {
                return false;
            }
        }

        public static async Task<bool> SaveToFile(string sourcePath, string destinationPath)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(destinationPath)!);
                await Task.Run(() => File.Copy(sourcePath, destinationPath, true));
                return true;
            }
            catch
            {
                return false;
            }
        }

        public static async Task SendNotification(string title, string body, string? imagePath = null)
        {
            var args = imagePath != null
                ? $"-i \"{imagePath}\" \"{title}\" \"{body}\""
                : $"\"{title}\" \"{body}\"";
            await RunProcess("notify-send", args);
        }

        private static async Task<(int X, int Y, int W, int H)?> GetFocusedViewGeometry()
        {
            try
            {
                var result = await CallWayfireIpc("window-rules/get-focused-view");
                if (result.TryGetProperty("info", out var info) && info.ValueKind != JsonValueKind.Null)
                {
                    if (info.TryGetProperty("geometry", out var geo))
                    {
                        var x = geo.GetProperty("x").GetInt32();
                        var y = geo.GetProperty("y").GetInt32();
                        var w = geo.GetProperty("width").GetInt32();
                        var h = geo.GetProperty("height").GetInt32();
                        return (x, y, w, h);
                    }
                }
            }
            catch
            {
                // Wayfire IPC not available
            }

            return null;
        }

        private static async Task<JsonElement> CallWayfireIpc(string method)
        {
            var socketPath = Environment.GetEnvironmentVariable("WAYFIRE_SOCKET")
                ?? Environment.GetEnvironmentVariable("_WAYFIRE_SOCKET")
                ?? FindWayfireSocket();

            using var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
            socket.Connect(new UnixDomainSocketEndPoint(socketPath));

            var msg = $"{{\"method\":\"{method}\"}}";
            var payload = Encoding.UTF8.GetBytes(msg);
            var header = BitConverter.GetBytes((uint)payload.Length);
            await socket.SendAsync(header);
            await socket.SendAsync(payload);

            var lenBuf = new byte[4];
            await ReadExact(socket, lenBuf, 4);
            var len = BitConverter.ToInt32(lenBuf, 0);
            var msgBuf = new byte[len];
            await ReadExact(socket, msgBuf, len);

            var json = Encoding.UTF8.GetString(msgBuf);
            using var doc = JsonDocument.Parse(json);
            return doc.RootElement.Clone();
        }

        private static string FindWayfireSocket()
        {
            var runtimeDir = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
            if (runtimeDir != null)
            {
                var files = Directory.GetFiles(runtimeDir, "wayfire-*.socket");
                if (files.Length > 0) return files[0];
            }

            var tmpFiles = Directory.GetFiles("/tmp", "wayfire-*.socket");
            if (tmpFiles.Length > 0) return tmpFiles[0];
            throw new FileNotFoundException("No Wayfire IPC socket found.");
        }

        private static async Task ReadExact(Socket socket, byte[] buffer, int count)
        {
            int offset = 0;
            while (offset < count)
            {
                var seg = new ArraySegment<byte>(buffer, offset, count - offset);
                var read = await socket.ReceiveAsync(seg, SocketFlags.None);
                if (read == 0) throw new IOException("Socket closed");
                offset += read;
            }
        }

        private static async Task<bool> RunProcess(string fileName, string arguments)
        {
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = fileName,
                    Arguments = arguments,
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true
                };

                using var process = Process.Start(psi);
                if (process == null) return false;
                await process.WaitForExitAsync();
                return process.ExitCode == 0;
            }
            catch
            {
                return false;
            }
        }

        private static async Task<string?> RunProcessWithOutput(string fileName, string arguments = "")
        {
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = fileName,
                    Arguments = arguments,
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true
                };

                using var process = Process.Start(psi);
                if (process == null) return null;
                var output = await process.StandardOutput.ReadToEndAsync();
                await process.WaitForExitAsync();
                return process.ExitCode == 0 ? output : null;
            }
            catch
            {
                return null;
            }
        }
    }
}
