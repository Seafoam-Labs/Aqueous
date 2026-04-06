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
            var (bar, barLeft, barCenter, barRight) = CreateBar(app);
            bar.GtkWindow.SetCssClasses(new string[] { "bar-window" });

            // Bar transparency CSS
            var barCss = Gtk.CssProvider.New();
            barCss.LoadFromString(@"
                window.bar-window,
                window.bar-window.background {
                    background: transparent !important;
                    background-color: transparent !important;
                    background-image: none !important;
                }
                window.bar-window decoration {
                    background: transparent !important;
                    background-image: none !important;
                }
                .bar-layout {
                    background: transparent !important;
                    background-color: transparent !important;
                    background-image: none !important;
                }
                .bar-side {
                    background-color: #313244;
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
                800); // STYLE_PROVIDER_PRIORITY_USER

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

            // --- Clock Tray Widget ---
            var clock = new Aqueous.Widgets.Clock.ClockTrayWidget(is24Hour: true);
            barCenter.GtkBox.Append(clock.Label);
            clock.Start();

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

    private static (AstalWindow window, AstalBox left, AstalBox center, AstalBox right) CreateBar(AstalApplication app)
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

        // Main layout container
        var layout = new AstalBox();
        layout.Vertical = false;
        layout.GtkBox.Hexpand = true;
        layout.GtkBox.AddCssClass("bar-layout");
        window.GtkWindow.SetChild(layout.GtkBox);

        // Single centered bar box
        var bar = new AstalBox();
        bar.Vertical = false;
        bar.GtkBox.Hexpand = false;
        bar.GtkBox.Halign = Align.Center;
        bar.GtkBox.AddCssClass("bar-section");
        // Left spacer
        var leftSpacer = new AstalBox();
        leftSpacer.GtkBox.Hexpand = true;
        leftSpacer.GtkBox.AddCssClass("bar-side");
        leftSpacer.GtkBox.Opacity = 0;
        layout.GtkBox.Append(leftSpacer.GtkBox);

        layout.GtkBox.Append(bar.GtkBox);

        // Right spacer
        var rightSpacer = new AstalBox();
        rightSpacer.GtkBox.Hexpand = true;
        rightSpacer.GtkBox.AddCssClass("bar-side");
        rightSpacer.GtkBox.Opacity = 0;
        layout.GtkBox.Append(rightSpacer.GtkBox);

        // Left content area (inside the single box)
        var left = new AstalBox();
        left.Vertical = false;
        left.GtkBox.Hexpand = true;
        left.GtkBox.Halign = Align.Start;
        bar.GtkBox.Append(left.GtkBox);

        // Center content area
        var center = new AstalBox();
        center.Vertical = false;
        center.GtkBox.Hexpand = true;
        center.GtkBox.Halign = Align.Center;
        bar.GtkBox.Append(center.GtkBox);

        // Right content area
        var right = new AstalBox();
        right.Vertical = false;
        right.GtkBox.Hexpand = true;
        right.GtkBox.Halign = Align.End;
        bar.GtkBox.Append(right.GtkBox);

        // --- Populate sections ---
        // Left: start menu button will be prepended here

        return (window, left, center, right);
    }
}