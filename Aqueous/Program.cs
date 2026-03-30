using System;
using System.IO;
using Gtk;

using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Aqueous.Features.SnapTo;
using Aqueous.Features.AudioSwitcher;
using Aqueous.Widgets.AudioTray;
using Aqueous.Features.AppLauncher;
using Aqueous.Widgets.StartMenu;
using Aqueous.Features.Settings;
using Aqueous.Features.Bluetooth;
using Aqueous.Widgets.BluetoothTray;
using Aqueous.Features.Dock;
using Aqueous.Features.Wallpaper;

public class Program
{
    private static SnapToService? _snapToService;
    private static AudioSwitcherService? _audioSwitcherService;
    private static AppLauncherService? _appLauncherService;
    private static SettingsService? _settingsService;
    private static BluetoothService? _bluetoothService;
    private static DockService? _dockService;
    private static WallpaperService? _wallpaperService;
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

            // Load AppLauncher CSS
            LoadAppLauncherCss();

            // Load Settings CSS
            LoadSettingsCss();

            // --- Bar Window ---
            var (bar, barLeft, barRight) = CreateBar(app);

            // Bar transparency CSS
            var barCss = Gtk.CssProvider.New();
            barCss.LoadFromString(@"
                window.bar-window {
                    background: transparent;
                    background-color: transparent;
                }
                window.bar-window decoration {
                    background: transparent;
                }
                .bar-layout {
                    background: transparent;
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

            // --- AppLauncher Service ---
            _appLauncherService = new AppLauncherService(app);
            _appLauncherService.Start();

            // --- Settings Service ---
            _settingsService = new SettingsService(app);
            _settingsService.Start();

            // --- Wallpaper Service ---
            LoadWallpaperCss();
            _wallpaperService = new WallpaperService(app, _settingsService!);
            _wallpaperService.Start();

            // --- Bluetooth Service ---
            LoadBluetoothCss();
            _bluetoothService = new BluetoothService(app);
            _bluetoothService.Start();

            // --- Audio Tray Widget ---
            LoadAudioTrayCss();
            var audioTray = new AudioTrayWidget(_audioSwitcherService);
            barRight.GtkBox.Append(audioTray.Button);

            // --- Bluetooth Tray Widget ---
            LoadBluetoothTrayCss();
            var bluetoothTray = new BluetoothTrayWidget(_bluetoothService!);
            barRight.GtkBox.Append(bluetoothTray.Button);

            // --- Start Menu Widget ---
            LoadStartMenuCss();
            var startMenu = new StartMenuWidget(app, _settingsService!);
            barLeft.GtkBox.Prepend(startMenu.Button);

            // --- Dock Service ---
            LoadDockCss();
            _dockService = new DockService(app, _settingsService!);
            _dockService.Start();
        };

        app.GtkApplication.Run(args);
        _snapToService?.Stop();
        _audioSwitcherService?.Stop();
        _appLauncherService?.Stop();
        _settingsService?.Stop();
        _bluetoothService?.Stop();
        _dockService?.Stop();
        _wallpaperService?.Stop();
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

    private static void LoadAppLauncherCss()
    {
        var cssProvider = Gtk.CssProvider.New();
        var cssPath = Path.Combine(AppContext.BaseDirectory, "Features", "AppLauncher", "applauncher.css");
        if (File.Exists(cssPath))
        {
            cssProvider.LoadFromPath(cssPath);
            Gtk.StyleContext.AddProviderForDisplay(
                Gdk.Display.GetDefault()!,
                cssProvider,
                Gtk.Constants.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }
    }

    private static void LoadSettingsCss()
    {
        var cssProvider = Gtk.CssProvider.New();
        var cssPath = Path.Combine(AppContext.BaseDirectory, "Features", "Settings", "settings.css");
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

    private static void LoadBluetoothCss()
    {
        var cssProvider = Gtk.CssProvider.New();
        var cssPath = Path.Combine(AppContext.BaseDirectory, "Features", "Bluetooth", "bluetooth.css");
        if (File.Exists(cssPath))
        {
            cssProvider.LoadFromPath(cssPath);
            Gtk.StyleContext.AddProviderForDisplay(
                Gdk.Display.GetDefault()!,
                cssProvider,
                Gtk.Constants.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }
    }

    private static void LoadBluetoothTrayCss()
    {
        var cssProvider = Gtk.CssProvider.New();
        var cssPath = Path.Combine(AppContext.BaseDirectory, "Widgets", "BluetoothTray", "bluetoothtray.css");
        if (File.Exists(cssPath))
        {
            cssProvider.LoadFromPath(cssPath);
            Gtk.StyleContext.AddProviderForDisplay(
                Gdk.Display.GetDefault()!,
                cssProvider,
                Gtk.Constants.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }
    }

    private static void LoadDockCss()
    {
        var cssProvider = Gtk.CssProvider.New();
        var cssPath = Path.Combine(AppContext.BaseDirectory, "Features", "Dock", "dock.css");
        if (File.Exists(cssPath))
        {
            cssProvider.LoadFromPath(cssPath);
            Gtk.StyleContext.AddProviderForDisplay(
                Gdk.Display.GetDefault()!,
                cssProvider,
                Gtk.Constants.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }
    }

    private static void LoadWallpaperCss()
    {
        var cssProvider = Gtk.CssProvider.New();
        var cssPath = Path.Combine(AppContext.BaseDirectory, "Features", "Wallpaper", "wallpaper.css");
        if (File.Exists(cssPath))
        {
            cssProvider.LoadFromPath(cssPath);
            Gtk.StyleContext.AddProviderForDisplay(
                Gdk.Display.GetDefault()!,
                cssProvider,
                Gtk.Constants.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }
    }

    private static void LoadStartMenuCss()
    {
        var cssProvider = Gtk.CssProvider.New();
        var cssPath = Path.Combine(AppContext.BaseDirectory, "Widgets", "StartMenu", "startmenu.css");
        if (File.Exists(cssPath))
        {
            cssProvider.LoadFromPath(cssPath);
            Gtk.StyleContext.AddProviderForDisplay(
                Gdk.Display.GetDefault()!,
                cssProvider,
                Gtk.Constants.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }
    }

    private static (AstalWindow window, AstalBox left, AstalBox right) CreateBar(AstalApplication app)
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
        // Left: start menu button will be prepended here

        // Center: clock placeholder
        center.GtkBox.Append(Label.New(DateTime.Now.ToString("ddd MMM dd  HH:mm")));

        return (window, left, right);
    }
}
