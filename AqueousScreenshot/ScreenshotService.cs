using System;
using System.Linq;
using System.Threading.Tasks;
using Aqueous.Bindings.AstalGTK4.Services;

namespace AqueousScreenshot
{
    public class ScreenshotService
    {
        private readonly AstalApplication _app;
        private ScreenshotWindow? _window;

        public ScreenshotService(AstalApplication app)
        {
            _app = app;
        }

        public void Start(string[] args)
        {
            var mode = ParseMode(args);
            var clipboard = args.Contains("--clipboard");
            var delayStr = GetArgValue(args, "--delay");
            int delay = 0;
            if (delayStr != null) int.TryParse(delayStr, out delay);

            if (mode != CaptureMode.Interactive)
            {
                _ = RunHeadless(mode, clipboard, delay);
            }
            else
            {
                _window = new ScreenshotWindow(_app, this);
                _window.Show();
            }
        }

        public async Task<string?> Capture(CaptureMode mode, int delaySeconds = 0)
        {
            if (delaySeconds > 0)
                await Task.Delay(delaySeconds * 1000);

            return mode switch
            {
                CaptureMode.Fullscreen => await CaptureBackend.CaptureFullscreen(),
                CaptureMode.ActiveWindow => await CaptureBackend.CaptureActiveWindow(),
                CaptureMode.Region => await CaptureBackend.CaptureInteractiveRegion(),
                _ => null
            };
        }

        private async Task RunHeadless(CaptureMode mode, bool clipboard, int delay)
        {
            var path = await Capture(mode, delay);

            if (path != null)
            {
                if (clipboard)
                {
                    await CaptureBackend.CopyToClipboard(path);
                    await CaptureBackend.SendNotification("Screenshot Captured", "Copied to clipboard");
                }
                else
                {
                    await CaptureBackend.SendNotification("Screenshot Captured", path, path);
                }

                Console.WriteLine(path);
            }
            else
            {
                Console.Error.WriteLine("Screenshot capture failed or was cancelled.");
            }

            _app.GtkApplication.Quit();
        }

        private static CaptureMode ParseMode(string[] args)
        {
            if (args.Contains("--fullscreen")) return CaptureMode.Fullscreen;
            if (args.Contains("--active-window")) return CaptureMode.ActiveWindow;
            if (args.Contains("--region")) return CaptureMode.Region;
            return CaptureMode.Interactive;
        }

        private static string? GetArgValue(string[] args, string key)
        {
            for (int i = 0; i < args.Length - 1; i++)
            {
                if (args[i] == key) return args[i + 1];
            }
            return null;
        }
    }

    public enum CaptureMode
    {
        Interactive,
        Fullscreen,
        ActiveWindow,
        Region
    }
}
