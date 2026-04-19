using System;
using System.Threading.Tasks;
using Aqueous.Features.Settings;

namespace Aqueous.Features.Corners
{
    public class CornersService
    {
        private static CornersService? _instance;
        public static CornersService Instance => _instance ??= new CornersService();

        public Task SetEnabled(bool enabled)
        {
            try
            {
                var cfg = WayfireConfigService.Instance;
                cfg.SetString("aqueous-corners", "enabled", enabled ? "true" : "false");
                cfg.Save();
            }
            catch (Exception ex) { Console.Error.WriteLine($"[CornersService] {ex.Message}"); }
            return Task.CompletedTask;
        }

        public Task SetRadius(int radius)
        {
            try
            {
                var cfg = WayfireConfigService.Instance;
                cfg.SetString("aqueous-corners", "corner_radius", radius.ToString());
                cfg.Save();
            }
            catch (Exception ex) { Console.Error.WriteLine($"[CornersService] {ex.Message}"); }
            return Task.CompletedTask;
        }

        public Task SetColor(string color)
        {
            try
            {
                var cfg = WayfireConfigService.Instance;
                cfg.SetString("aqueous-corners", "corner_color", color);
                cfg.Save();
            }
            catch (Exception ex) { Console.Error.WriteLine($"[CornersService] {ex.Message}"); }
            return Task.CompletedTask;
        }
    }
}
