using System;
using System.Linq;
using Gtk;
using Gio;

using Aqueous.Bindings.AstalGTK4.Services;

public class Program
{
    public static void Main(string[] args)
    {
        Console.WriteLine("Starting Astal App...");

        var astalApp = new AstalApplication();
        var app = astalApp.GtkApplication;
        app.ApplicationId = "com.example.astal-app";

        app.OnActivate += (sender, e) => {
            var astalWin = new AstalWindow();
            var win = astalWin.GtkWindow;
            
            app.AddWindow(win);

            astalWin.Namespace = "Aqueous";
            astalWin.Layer = Aqueous.Bindings.AstalGTK4.AstalLayer.ASTAL_LAYER_TOP;
            astalWin.Anchor = Aqueous.Bindings.AstalGTK4.AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP | 
                              Aqueous.Bindings.AstalGTK4.AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_LEFT | 
                              Aqueous.Bindings.AstalGTK4.AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT;

            win.SetDefaultSize(400, 50);
            win.Title = "Aqueous Astal Window";

            var astalBox = new AstalBox();
            astalBox.Vertical = false;
            win.SetChild(astalBox.GtkBox);

            var label = Gtk.Label.New("Hello from Aqueous!");
            astalBox.GtkBox.Append(label);

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