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
using Aqueous.Features.Bar;
using Aqueous.Features.SystemTray;
using Aqueous.Features.WindowManager;
using Aqueous.Widgets.SystemTray;
using Aqueous.Widgets.WindowList;
using Aqueous.Widgets.WorkspaceSwitcher;

public class Program
{
    private static SnapToService? _snapToService;
    private static AudioSwitcherService? _audioSwitcherService;
    private static AppLauncherService? _appLauncherService;
    private static SettingsService? _settingsService;
    private static BluetoothService? _bluetoothService;
    private static DockService? _dockService;
    private static WallpaperService? _wallpaperService;
    private static BarService? _barService;
    private static SystemTrayService? _systemTrayService;
    private static WindowManagerService? _windowManagerService;

    public static void Main(string[] args)
    {
        var app = new AstalApplication();
        app.GtkApplication.ApplicationId = "com.example.aqueous";

        app.GtkApplication.OnActivate += (sender, e) =>
        {
            // Load Bar CSS
            LoadBarCss();

            // Load SnapTo CSS
            LoadSnapToCss();

            // Load AudioSwitcher CSS
            LoadAudioSwitcherCss();

            // Load AppLauncher CSS
            LoadAppLauncherCss();

            // Load Settings CSS
            LoadSettingsCss();

            // --- Bar Service ---
            _barService = new BarService(app);
            _barService.Start();
            var barWindow = _barService.Window!;
            var barLeft = barWindow.LeftSection;
            var barCenter = barWindow.CenterSection;
            var barRight = barWindow.RightSection;

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
            var clock = new Aqueous.Widgets.Clock.ClockTrayWidget(is24Hour: false);
            barCenter.GtkBox.Append(clock.Label);
            clock.Start();

            // --- Start Menu Widget ---
            LoadStartMenuCss();
            var startMenu = new StartMenuWidget(app, _settingsService!);
            barLeft.GtkBox.Prepend(startMenu.Button);

            // --- System Tray Widget ---
            LoadSystemTrayCss();
            _systemTrayService = new SystemTrayService();
            _systemTrayService.Start();
            var systemTray = new SystemTrayWidget(_systemTrayService, barWindow);
            barRight.GtkBox.Append(systemTray.Box);

            // --- Window Manager Service ---
            _windowManagerService = new WindowManagerService();
            _windowManagerService.Start();

            // --- Window List Widget ---
            LoadWindowListCss();
            var windowList = new WindowListWidget(_windowManagerService);
            barCenter.GtkBox.Append(windowList.Button);

            // --- Workspace Switcher Widget (disabled) ---
            // LoadWorkspaceSwitcherCss();
            // var workspaceSwitcher = new WorkspaceSwitcherWidget(_windowManagerService);
            // barLeft.GtkBox.Append(workspaceSwitcher.Box);

            // --- Dock Service ---
            LoadDockCss();
            _dockService = new DockService(app, _settingsService!, _windowManagerService);
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
        _systemTrayService?.Dispose();
        _windowManagerService?.Dispose();
        _barService?.Stop();
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

    private static void LoadSystemTrayCss()
    {
        var cssProvider = Gtk.CssProvider.New();
        var cssPath = Path.Combine(AppContext.BaseDirectory, "Widgets", "SystemTray", "systemtray.css");
        if (File.Exists(cssPath))
        {
            cssProvider.LoadFromPath(cssPath);
            Gtk.StyleContext.AddProviderForDisplay(
                Gdk.Display.GetDefault()!,
                cssProvider,
                Gtk.Constants.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }
    }

    private static void LoadWindowListCss()
    {
        var cssProvider = Gtk.CssProvider.New();
        var cssPath = Path.Combine(AppContext.BaseDirectory, "Widgets", "WindowList", "windowlist.css");
        if (File.Exists(cssPath))
        {
            cssProvider.LoadFromPath(cssPath);
            Gtk.StyleContext.AddProviderForDisplay(
                Gdk.Display.GetDefault()!,
                cssProvider,
                Gtk.Constants.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }
    }

    private static void LoadWorkspaceSwitcherCss()
    {
        var cssProvider = Gtk.CssProvider.New();
        var cssPath = Path.Combine(AppContext.BaseDirectory, "Widgets", "WorkspaceSwitcher", "workspaceswitcher.css");
        if (File.Exists(cssPath))
        {
            cssProvider.LoadFromPath(cssPath);
            Gtk.StyleContext.AddProviderForDisplay(
                Gdk.Display.GetDefault()!,
                cssProvider,
                Gtk.Constants.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }
    }

    private static void LoadBarCss()
    {
        var cssProvider = Gtk.CssProvider.New();
        var cssPath = Path.Combine(AppContext.BaseDirectory, "Features", "Bar", "bar.css");
        if (File.Exists(cssPath))
        {
            cssProvider.LoadFromPath(cssPath);
            Gtk.StyleContext.AddProviderForDisplay(
                Gdk.Display.GetDefault()!,
                cssProvider,
                Gtk.Constants.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }
    }
}