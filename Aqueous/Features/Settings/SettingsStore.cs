using System;
using System.IO;
using System.Text.Json;

namespace Aqueous.Features.Settings
{
    public class SettingsData
    {
        // General
        public bool AutostartEnabled { get; set; }
        public string BarPosition { get; set; } = "Top";
        public string ThemeAccentColor { get; set; } = "#89b4fa";
        public double PanelOpacity { get; set; } = 1.0;

        // SnapTo
        public string ActiveSnapLayout { get; set; } = "Priority Grid";
        public bool SnapToEnabled { get; set; } = true;
        public string SnapToKeybind { get; set; } = "Super+Ctrl+S";

        // Audio
        public string DefaultOutputDevice { get; set; } = "";
        public bool ShowTrayWidget { get; set; } = true;
        public int VolumeStep { get; set; } = 5;

        // AppLauncher
        public string LaunchKeybind { get; set; } = "Alt+Space";
        public int MaxResults { get; set; } = 20;

        // Bluetooth
        public bool ShowBluetoothTray { get; set; } = true;
        public bool BluetoothAutoConnect { get; set; } = true;
        // Dock
        public string DockPosition { get; set; } = "Left";

        // Wallpaper
        public string WallpaperImagePath { get; set; } = "";
        public string WallpaperScaleMode { get; set; } = "Fill";
        public string WallpaperFallbackColor { get; set; } = "#1e1e2e";

        // HDR / Display
        public bool HdrEnabled { get; set; } = false;
        public bool HdrDisableIncompatibleAnimations { get; set; } = true;
        public string? PreHdrPluginList { get; set; } = null;
        public string? PreHdrOpenAnimation { get; set; } = null;
        public string? PreHdrCloseAnimation { get; set; } = null;
        public string? HdrIccProfilePath { get; set; } = null;

        // Corners
        public bool CornersEnabled { get; set; } = true;
        public int CornersRadius { get; set; } = 12;
        public string CornersColor { get; set; } = "#1A1A1AFF";

        // Advanced UI
        public bool ShowAdvancedIniKeys { get; set; } = false;
    }

    public class SettingsStore
    {
        private static readonly string ConfigDir =
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".config", "aqueous");

        private static readonly string ConfigPath =
            Path.Combine(ConfigDir, "settings.json");

        private static SettingsStore? _instance;
        public static SettingsStore Instance => _instance ??= new SettingsStore();

        public SettingsData Data { get; private set; } = new();

        public event Action? Changed;

        public void Load()
        {
            try
            {
                if (File.Exists(ConfigPath))
                {
                    var json = File.ReadAllText(ConfigPath);
                    Data = JsonSerializer.Deserialize(json, SettingsJsonContext.Default.SettingsData) ?? new SettingsData();
                }
            }
            catch
            {
                Data = new SettingsData();
            }
        }

        public void Save()
        {
            try
            {
                Directory.CreateDirectory(ConfigDir);
                var json = JsonSerializer.Serialize(Data, SettingsJsonContext.Default.SettingsData);
                File.WriteAllText(ConfigPath, json);
            }
            catch
            {
                // Ignore save errors
            }
        }

        public void NotifyChanged()
        {
            Save();
            Changed?.Invoke();
        }
    }
}
