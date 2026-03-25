using System;
using Gtk;

using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;

public class Program
{
    public static void Main(string[] args)
    {
        var app = new AstalApplication();
        app.GtkApplication.ApplicationId = "com.example.aqueous";

        app.GtkApplication.OnActivate += (sender, e) =>
        {
            // --- Bar Window ---
            var bar = CreateBar(app);
            bar.GtkWindow.Present();
        };

        app.GtkApplication.Run(args);
    }

    private static AstalWindow CreateBar(AstalApplication app)
    {
        var window = new AstalWindow();
        app.GtkApplication.AddWindow(window.GtkWindow);

        window.Namespace = "bar";
        window.Layer = AstalLayer.ASTAL_LAYER_TOP;
        window.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_EXCLUSIVE;
        window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP
                      | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_LEFT
                      | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT;

        window.GtkWindow.SetDefaultSize(-1, 32);

        // Main horizontal layout: left | center | right
        var layout = new AstalBox();
        layout.Vertical = false;
        window.GtkWindow.SetChild(layout.GtkBox);

        // Left section
        var left = new AstalBox();
        left.Vertical = false;
        left.GtkBox.Hexpand = true;
        left.GtkBox.Halign = Align.Start;
        layout.GtkBox.Append(left.GtkBox);

        // Center section
        var center = new AstalBox();
        center.Vertical = false;
        center.GtkBox.Hexpand = true;
        center.GtkBox.Halign = Align.Center;
        layout.GtkBox.Append(center.GtkBox);

        // Right section
        var right = new AstalBox();
        right.Vertical = false;
        right.GtkBox.Hexpand = true;
        right.GtkBox.Halign = Align.End;
        layout.GtkBox.Append(right.GtkBox);

        // --- Populate sections ---
        // Left: workspaces / launcher placeholder
        left.GtkBox.Append(Label.New("Aqueous"));

        // Center: clock placeholder
        center.GtkBox.Append(Label.New(DateTime.Now.ToString("ddd MMM dd  HH:mm")));

        // Right: system tray / status placeholder
        right.GtkBox.Append(Label.New("status"));

        return window;
    }
}
