using System;
using System.IO;
using Aqueous.Bindings.AstalGTK4.Services;

namespace AqueousScreenshot
{
    public class Program
    {
        public static void Main(string[] args)
        {
            var app = new AstalApplication();
            app.GtkApplication.ApplicationId = "com.example.aqueous-screenshot";

            app.GtkApplication.OnActivate += (sender, e) =>
            {
                LoadCss("screenshot.css");

                CaptureBackend.App = app;
                var service = new ScreenshotService(app);
                service.Start(args);
            };

            app.GtkApplication.Run(args);
        }

        private static void LoadCss(string relativePath)
        {
            var cssPath = Path.Combine(AppContext.BaseDirectory, relativePath);

            if (File.Exists(cssPath))
            {
                var cssProvider = Gtk.CssProvider.New();
                cssProvider.LoadFromPath(cssPath);
                Gtk.StyleContext.AddProviderForDisplay(
                    Gdk.Display.GetDefault()!,
                    cssProvider,
                    Gtk.Constants.STYLE_PROVIDER_PRIORITY_APPLICATION);
            }
        }
    }
}
