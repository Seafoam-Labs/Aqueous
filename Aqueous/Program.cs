using System;
using System.IO;
using Gtk;

using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Aqueous.Features.SnapTo;
using Aqueous.Features.AudioSwitcher;
using Aqueous.Widgets.AudioTray;

public class Program
{
    private static SnapToService? _snapToService;
    private static AudioSwitcherService? _audioSwitcherService;
    public static void Main(string[] args)
    {
        var app = new AstalApplication();
        app.GtkApplication.ApplicationId = "com.example.aqueous";

        app.GtkApplication.OnActivate += (sender, e) =>
        {
            // Load SnapTo CSS
            LoadSnapToCss();

            // Load AudioSwitcher CSS
            LoadAudioSwitcherCss();

            // --- Bar Window ---
            var (bar, barRight) = CreateBar(app);

            // Bar transparency CSS
            var barCss = Gtk.CssProvider.New();
            barCss.LoadFromString(@"
                window.bar-window {
                    background-color: transparent;
                }
                .bar-layout {
                    background-color: transparent;
                }
                .bar-section {
                    background-color: #1e1e2e;
                    border-radius: 8px;
                    padding: 4px 8px;
                }
            ");
            Gtk.StyleContext.AddProviderForDisplay(
                Gdk.Display.GetDefault()!,
                barCss,
                Gtk.Constants.STYLE_PROVIDER_PRIORITY_APPLICATION);

            bar.GtkWindow.Present();

            // --- SnapTo Service ---
            _snapToService = new SnapToService(app);
            _snapToService.Start();

            // --- AudioSwitcher Service ---
            _audioSwitcherService = new AudioSwitcherService(app);
            _audioSwitcherService.Start();

            // --- Audio Tray Widget ---
            LoadAudioTrayCss();
            var audioTray = new AudioTrayWidget(_audioSwitcherService);
            barRight.GtkBox.Append(audioTray.Button);
        };

        app.GtkApplication.Run(args);
        _snapToService?.Stop();
        _audioSwitcherService?.Stop();
    }

    private static void LoadAudioTrayCss()
    {
        var cssProvider = Gtk.CssProvider.New();
        var cssPath = Path.Combine(AppContext.BaseDirectory, "Widgets", "AudioTray", "audiotray.css");
        if (File.Exists(cssPath))
        {
            cssProvider.LoadFromPath(cssPath);
            Gtk.StyleContext.AddProviderForDisplay(
                Gdk.Display.GetDefault()!,
                cssProvider,
                Gtk.Constants.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }
    }

    private static void LoadAudioSwitcherCss()
    {
        var cssProvider = Gtk.CssProvider.New();
        var cssPath = Path.Combine(AppContext.BaseDirectory, "Features", "AudioSwitcher", "audioswitcher.css");
        if (File.Exists(cssPath))
        {
            cssProvider.LoadFromPath(cssPath);
            Gtk.StyleContext.AddProviderForDisplay(
                Gdk.Display.GetDefault()!,
                cssProvider,
                Gtk.Constants.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }
    }

    private static void LoadSnapToCss()
    {
        var cssProvider = Gtk.CssProvider.New();
        var cssPath = Path.Combine(AppContext.BaseDirectory, "Features", "SnapTo", "snapto.css");
        if (File.Exists(cssPath))
        {
            cssProvider.LoadFromPath(cssPath);
            Gtk.StyleContext.AddProviderForDisplay(
                Gdk.Display.GetDefault()!,
                cssProvider,
                Gtk.Constants.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }
    }

    private static (AstalWindow window, AstalBox right) CreateBar(AstalApplication app)
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
        window.GtkWindow.AddCssClass("bar-window");

        // Main horizontal layout: left | center | right
        var layout = new AstalBox();
        layout.Vertical = false;
        layout.GtkBox.AddCssClass("bar-layout");
        window.GtkWindow.SetChild(layout.GtkBox);

        // Left section
        var left = new AstalBox();
        left.Vertical = false;
        left.GtkBox.Hexpand = true;
        left.GtkBox.Halign = Align.Start;
        left.GtkBox.AddCssClass("bar-section");
        layout.GtkBox.Append(left.GtkBox);

        // Center section
        var center = new AstalBox();
        center.Vertical = false;
        center.GtkBox.Hexpand = true;
        center.GtkBox.Halign = Align.Center;
        center.GtkBox.AddCssClass("bar-section");
        layout.GtkBox.Append(center.GtkBox);

        // Right section
        var right = new AstalBox();
        right.Vertical = false;
        right.GtkBox.Hexpand = true;
        right.GtkBox.Halign = Align.End;
        right.GtkBox.AddCssClass("bar-section");
        layout.GtkBox.Append(right.GtkBox);

        // --- Populate sections ---
        // Left: workspaces / launcher placeholder
        left.GtkBox.Append(Label.New("Aqueous"));

        // Center: clock placeholder
        center.GtkBox.Append(Label.New(DateTime.Now.ToString("ddd MMM dd  HH:mm")));

        return (window, right);
    }
}
