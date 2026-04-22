using System;
using System.IO;
using System.Linq;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Aqueous.Helpers;

namespace Aqueous.Features.SnapTo
{
    public class WayfireEventClient : IDisposable
    {
        private Socket? _socket;
        private readonly string _socketPath;

        public WayfireEventClient()
        {
            _socketPath = WayfireSocket.Resolve();
        }

        public void Connect()
        {
            _socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
            try
            {
                _socket.Connect(new UnixDomainSocketEndPoint(_socketPath));
            }
            catch
            {
                WayfireSocket.Invalidate();
                throw;
            }
        }

        public async Task SendJson(string json)
        {
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
            using var doc = JsonDocument.Parse(json);
            return doc.RootElement.Clone();
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
            var eventsJson = string.Join(",", events.Select(e => $"\"{e}\""));
            var json = $"{{\"method\":\"window-rules/events/watch\",\"data\":{{\"events\":[{eventsJson}]}}}}";
            await SendJson(json);
            await ReadMessage(CancellationToken.None);
        }

        public void Dispose()
        {
            _socket?.Dispose();
        }
    }
}
