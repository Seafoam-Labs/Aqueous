using System;
using System.Linq;
using Gtk;
using Gio;

using Aqueous.Bindings.AstalGTK4.Services;
using Aqueous.Bindings.AstalApp.Services;

public class Program
{
    public static void Main(string[] args)
    {
        Console.WriteLine("Starting Astal App...");

        var astalApp = new AstalApplication();
        var app = astalApp.GtkApplication;
        app.ApplicationId = "com.example.astal-app";

        var apps = new AstalAppsApps();

        app.OnActivate += (sender, e) => {
            var astalWin = new AstalWindow();
            var win = astalWin.GtkWindow;
            
            app.AddWindow(win);

            astalWin.Namespace = "Aqueous";
            astalWin.Layer = Aqueous.Bindings.AstalGTK4.AstalLayer.ASTAL_LAYER_TOP;
            astalWin.Anchor = Aqueous.Bindings.AstalGTK4.AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP |
                              Aqueous.Bindings.AstalGTK4.AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_LEFT;

            win.SetDefaultSize(400, 300);
            win.Title = "Aqueous Astal Window";

            var astalBox = new AstalBox();
            astalBox.Vertical = true;
            win.SetChild(astalBox.GtkBox);

            var label = Gtk.Label.New("Hello from Aqueous!");
            astalBox.GtkBox.Append(label);

            var queryLabel = Gtk.Label.New("Searching for 'term'...");
            astalBox.GtkBox.Append(queryLabel);
            

            var results = apps.FuzzyQuery("terminal").Take(5);
            foreach (var result in results)
            {
                var appLabel = Gtk.Label.New($"{result.Name}: {result.Description}");
                astalBox.GtkBox.Append(appLabel);
            }

            var astalSlider = new AstalSlider();
            astalSlider.Min = 0;
            astalSlider.Max = 100;
            astalSlider.Value = 50;
            astalBox.GtkBox.Append(astalSlider.GtkWidget);
            
            win.Present();
        };

        app.Run(args);
    }
}