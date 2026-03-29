using System;
using System.Diagnostics;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;

namespace Aqueous.Features.SnapTo
{
    public static class WayfireIpc
    {
        private static async Task<string> RunWfMsg(string args)
        {
            var psi = new ProcessStartInfo("wf-msg", args)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false
            };
            using var proc = Process.Start(psi);
            if (proc == null) return string.Empty;
            var output = await proc.StandardOutput.ReadToEndAsync();
            await proc.WaitForExitAsync();
            return output;
        }

        public static async Task<JsonElement[]> ListViews()
        {
            var json = await RunWfMsg("list-views");
            if (string.IsNullOrWhiteSpace(json)) return [];
            return JsonSerializer.Deserialize(json, SnapToJsonContext.Default.JsonElementArray) ?? [];
        }

        public static async Task<JsonElement?> GetFocusedView()
        {
            var views = await ListViews();
            return views.FirstOrDefault(v =>
                v.TryGetProperty("focused", out var f) && f.GetBoolean());
        }

        public static async Task SetViewGeometry(int viewId, int x, int y, int w, int h)
        {
            await RunWfMsg($"set-view-geometry {viewId} {x} {y} {w} {h}");
        }

        public static async Task<JsonElement[]> ListOutputs()
        {
            var json = await RunWfMsg("list-outputs");
            if (string.IsNullOrWhiteSpace(json)) return [];
            return JsonSerializer.Deserialize(json, SnapToJsonContext.Default.JsonElementArray) ?? [];
        }
    }
}
