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
            // Seed user CSS overrides on first run
            SeedUserCss();

            // Load all CSS (user overrides take priority)
            LoadCss(Path.Combine("Features", "Bar", "bar.css"));
            LoadCss(Path.Combine("Features", "SnapTo", "snapto.css"));
            LoadCss(Path.Combine("Features", "AudioSwitcher", "audioswitcher.css"));
            LoadCss(Path.Combine("Features", "AppLauncher", "applauncher.css"));
            LoadCss(Path.Combine("Features", "Settings", "settings.css"));

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
            LoadCss(Path.Combine("Features", "Wallpaper", "wallpaper.css"));
            _wallpaperService = new WallpaperService(app, _settingsService!);
            _wallpaperService.Start();

            // --- Bluetooth Service ---
            LoadCss(Path.Combine("Features", "Bluetooth", "bluetooth.css"));
            _bluetoothService = new BluetoothService(app);
            _bluetoothService.Start();

            // --- Audio Tray Widget ---
            LoadCss(Path.Combine("Widgets", "AudioTray", "audiotray.css"));
            var audioTray = new AudioTrayWidget(_audioSwitcherService);
            barRight.GtkBox.Append(audioTray.Button);

            // --- Bluetooth Tray Widget ---
            LoadCss(Path.Combine("Widgets", "BluetoothTray", "bluetoothtray.css"));
            var bluetoothTray = new BluetoothTrayWidget(_bluetoothService!, barWindow);
            barRight.GtkBox.Append(bluetoothTray.Button);

            // --- Clock Tray Widget ---
            var clock = new Aqueous.Widgets.Clock.ClockTrayWidget(is24Hour: false);
            barCenter.GtkBox.Append(clock.Label);
            clock.Start();

            // --- Start Menu Widget ---
            LoadCss(Path.Combine("Widgets", "StartMenu", "startmenu.css"));
            var startMenu = new StartMenuWidget(app, _settingsService!);
            barLeft.GtkBox.Prepend(startMenu.Button);

            // --- System Tray Widget ---
            LoadCss(Path.Combine("Widgets", "SystemTray", "systemtray.css"));
            _systemTrayService = new SystemTrayService();
            _systemTrayService.Start();
            var systemTray = new SystemTrayWidget(_systemTrayService, barWindow);
            barRight.GtkBox.Append(systemTray.Box);

            // --- Window Manager Service ---
            _windowManagerService = new WindowManagerService();
            _windowManagerService.Start();

            // --- Window List Widget ---
            LoadCss(Path.Combine("Widgets", "WindowList", "windowlist.css"));
            var windowList = new WindowListWidget(_windowManagerService);
            barCenter.GtkBox.Append(windowList.Button);

            // --- Workspace Switcher Widget (disabled) ---
            // LoadCss(Path.Combine("Widgets", "WorkspaceSwitcher", "workspaceswitcher.css"));
            // var workspaceSwitcher = new WorkspaceSwitcherWidget(_windowManagerService);
            // barLeft.GtkBox.Append(workspaceSwitcher.Box);

            // --- Dock Service ---
            LoadCss(Path.Combine("Features", "Dock", "dock.css"));
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

    private static void LoadCss(string relativePath)
    {
        var configDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "aqueous");

        var userCssPath = Path.Combine(configDir, relativePath);
        var defaultCssPath = Path.Combine(AppContext.BaseDirectory, relativePath);

        var cssPath = File.Exists(userCssPath) ? userCssPath : defaultCssPath;

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

    private static void SeedUserCss()
    {
        var configDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "aqueous");

        string[] cssFiles =
        [
            Path.Combine("Features", "AppLauncher", "applauncher.css"),
            Path.Combine("Features", "AudioSwitcher", "audioswitcher.css"),
            Path.Combine("Features", "Bar", "bar.css"),
            Path.Combine("Features", "Bluetooth", "bluetooth.css"),
            Path.Combine("Features", "Dock", "dock.css"),
            Path.Combine("Features", "Settings", "settings.css"),
            Path.Combine("Features", "SnapTo", "snapto.css"),
            Path.Combine("Features", "Wallpaper", "wallpaper.css"),
            Path.Combine("Widgets", "AudioTray", "audiotray.css"),
            Path.Combine("Widgets", "BluetoothTray", "bluetoothtray.css"),
            Path.Combine("Widgets", "StartMenu", "startmenu.css"),
            Path.Combine("Widgets", "SystemTray", "systemtray.css"),
            Path.Combine("Widgets", "WindowList", "windowlist.css"),
            Path.Combine("Widgets", "WorkspaceSwitcher", "workspaceswitcher.css"),
        ];

        foreach (var relativePath in cssFiles)
        {
            var dest = Path.Combine(configDir, relativePath);
            if (!File.Exists(dest))
            {
                var src = Path.Combine(AppContext.BaseDirectory, relativePath);
                if (File.Exists(src))
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                    File.Copy(src, dest);
                }
            }
        }
    }
}