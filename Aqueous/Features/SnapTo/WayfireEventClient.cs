using System;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Aqueous.Features.SnapTo
{
    public class WayfireEventClient : IDisposable
    {
        private Socket? _socket;
        private readonly string _socketPath;

        public WayfireEventClient()
        {
            _socketPath = Environment.GetEnvironmentVariable("_WAYFIRE_SOCKET")
                ?? FindWayfireSocket();
        }

        public void Connect()
        {
            _socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
            _socket.Connect(new UnixDomainSocketEndPoint(_socketPath));
        }

        public async Task SendJson(object message)
        {
            var json = JsonSerializer.Serialize(message);
            var payload = Encoding.UTF8.GetBytes(json);
            var header = BitConverter.GetBytes((uint)payload.Length);
            await _socket!.SendAsync(header);
            await _socket.SendAsync(payload);
        }

        public async Task<JsonElement> ReadMessage(CancellationToken ct)
        {
            var lenBuf = new byte[4];
            await ReadExact(lenBuf, 4, ct);
            var len = BitConverter.ToInt32(lenBuf, 0);

            var msgBuf = new byte[len];
            await ReadExact(msgBuf, len, ct);

            var json = Encoding.UTF8.GetString(msgBuf);
            return JsonSerializer.Deserialize<JsonElement>(json);
        }

        private async Task ReadExact(byte[] buffer, int count, CancellationToken ct)
        {
            int offset = 0;
            while (offset < count)
            {
                var seg = new ArraySegment<byte>(buffer, offset, count - offset);
                var read = await _socket!.ReceiveAsync(seg, SocketFlags.None, ct);
                if (read == 0) throw new IOException("Socket closed");
                offset += read;
            }
        }

        public async Task Subscribe(string[] events)
        {
            var msg = new
            {
                method = "window-rules/events/watch",
                data = new { events }
            };
            await SendJson(msg);
            await ReadMessage(CancellationToken.None);
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
            throw new FileNotFoundException(
                "No Wayfire IPC socket found. Ensure 'ipc' plugin is enabled and _WAYFIRE_SOCKET is set.");
        }

        public void Dispose()
        {
            _socket?.Dispose();
        }
    }
}
