using System;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using Aqueous.Helpers;

namespace Aqueous.Features.SnapTo
{
    public static class WayfireIpc
    {
        private static async Task<JsonElement> CallIpc(string method, JsonElement? data = null)
        {
            var socketPath = WayfireSocket.Resolve();

            using var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
            try
            {
                socket.Connect(new UnixDomainSocketEndPoint(socketPath));
            }
            catch
            {
                WayfireSocket.Invalidate();
                throw;
            }

            var msg = data.HasValue
                ? $"{{\"method\":\"{method}\",\"data\":{data.Value.GetRawText()}}}"
                : $"{{\"method\":\"{method}\"}}";

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

        public static async Task<JsonElement[]> ListViews()
        {
            var result = await CallIpc("window-rules/list-views");
            var len = result.GetArrayLength();
            var arr = new JsonElement[len];
            int i = 0;
            foreach (var item in result.EnumerateArray())
                arr[i++] = item.Clone();
            return arr;
        }

        public static async Task<JsonElement?> GetFocusedView()
        {
            var result = await CallIpc("window-rules/get-focused-view");
            if (result.TryGetProperty("info", out var info) && info.ValueKind != JsonValueKind.Null)
                return info.Clone();
            return null;
        }

        public static async Task SetViewGeometry(int viewId, int x, int y, int w, int h)
        {
            var dataJson = $"{{\"id\":{viewId},\"geometry\":{{\"x\":{x},\"y\":{y},\"width\":{w},\"height\":{h}}}}}";
            using var dataDoc = JsonDocument.Parse(dataJson);
            var data = dataDoc.RootElement.Clone();
            await CallIpc("window-rules/configure-view", data);
        }

        public static async Task<JsonElement[]> ListOutputs()
        {
            var result = await CallIpc("window-rules/list-outputs");
            var len = result.GetArrayLength();
            var arr = new JsonElement[len];
            int i = 0;
            foreach (var item in result.EnumerateArray())
                arr[i++] = item.Clone();
            return arr;
        }

        public static async Task<(int X, int Y)?> GetCursorPosition()
        {
            var result = await CallIpc("window-rules/get_cursor_position");
            if (result.TryGetProperty("pos", out var pos)
                && pos.TryGetProperty("x", out var x)
                && pos.TryGetProperty("y", out var y))
                return ((int)x.GetDouble(), (int)y.GetDouble());
            return null;
        }

        public static async Task FocusView(int viewId)
        {
            var dataJson = $"{{\"id\":{viewId}}}";
            using var dataDoc = JsonDocument.Parse(dataJson);
            var data = dataDoc.RootElement.Clone();
            await CallIpc("window-rules/focus-view", data);
        }

        public static async Task CloseView(int viewId)
        {
            var dataJson = $"{{\"id\":{viewId}}}";
            using var dataDoc = JsonDocument.Parse(dataJson);
            var data = dataDoc.RootElement.Clone();
            await CallIpc("window-rules/close-view", data);
        }

        public static async Task MinimizeView(int viewId, bool state)
        {
            var dataJson = $"{{\"id\":{viewId},\"minimized\":{(state ? "true" : "false")}}}";
            using var dataDoc = JsonDocument.Parse(dataJson);
            var data = dataDoc.RootElement.Clone();
            await CallIpc("window-rules/configure-view", data);
        }

        public static async Task SetViewFullscreen(int viewId, bool state)
        {
            var dataJson = $"{{\"id\":{viewId},\"fullscreen\":{(state ? "true" : "false")}}}";
            using var dataDoc = JsonDocument.Parse(dataJson);
            var data = dataDoc.RootElement.Clone();
            await CallIpc("window-rules/configure-view", data);
        }

        public static async Task MoveViewToWorkspace(int viewId, int wsX, int wsY)
        {
            var dataJson = $"{{\"id\":{viewId},\"workspace\":{{\"x\":{wsX},\"y\":{wsY}}}}}";
            using var dataDoc = JsonDocument.Parse(dataJson);
            var data = dataDoc.RootElement.Clone();
            await CallIpc("window-rules/configure-view", data);
        }

        public static async Task<JsonElement> GetWorkspace()
        {
            return await CallIpc("vswitch/get-workspace");
        }

        public static async Task SetWorkspace(int x, int y)
        {
            var dataJson = $"{{\"x\":{x},\"y\":{y}}}";
            using var dataDoc = JsonDocument.Parse(dataJson);
            var data = dataDoc.RootElement.Clone();
            await CallIpc("vswitch/set-workspace", data);
        }

        // --- Aqueous Corners plugin IPC ---

        public static async Task SetCornersEnabled(bool enabled)
        {
            var dataJson = $"{{\"enabled\":{(enabled ? "true" : "false")}}}";
            using var dataDoc = JsonDocument.Parse(dataJson);
            await CallIpc("wf/aqueous-corners/set-enabled", dataDoc.RootElement.Clone());
        }

        public static async Task SetCornerRadius(int radius)
        {
            var dataJson = $"{{\"radius\":{radius}}}";
            using var dataDoc = JsonDocument.Parse(dataJson);
            await CallIpc("wf/aqueous-corners/set-radius", dataDoc.RootElement.Clone());
        }

        public static async Task SetCornerColor(string color)
        {
            var dataJson = $"{{\"color\":\"{color}\"}}";
            using var dataDoc = JsonDocument.Parse(dataJson);
            await CallIpc("wf/aqueous-corners/set-color", dataDoc.RootElement.Clone());
        }

        public static async Task ExcludeViewFromCorners(int viewId)
        {
            var dataJson = $"{{\"view-id\":{viewId}}}";
            using var dataDoc = JsonDocument.Parse(dataJson);
            await CallIpc("wf/aqueous-corners/exclude-view", dataDoc.RootElement.Clone());
        }

        public static async Task IncludeViewInCorners(int viewId)
        {
            var dataJson = $"{{\"view-id\":{viewId}}}";
            using var dataDoc = JsonDocument.Parse(dataJson);
            await CallIpc("wf/aqueous-corners/include-view", dataDoc.RootElement.Clone());
        }

        public static async Task<JsonElement> GetCornersStatus()
        {
            return await CallIpc("wf/aqueous-corners/get-status");
        }
    }
}
