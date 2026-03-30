using Aqueous.Bindings.AstalGTK4.Services;
using Aqueous.Features.Settings;

namespace Aqueous.Features.Wallpaper
{
    public class WallpaperService
    {
        private readonly AstalApplication _app;
        private readonly SettingsService _settingsService;
        private WallpaperWindow? _window;

        public WallpaperService(AstalApplication app, SettingsService settingsService)
        {
            _app = app;
            _settingsService = settingsService;
        }

        public void Start()
        {
            _window = new WallpaperWindow(_app);
            _window.Show();
            ApplyWallpaper();
            _settingsService.Store.Changed += OnSettingsChanged;
        }

        public void Stop()
        {
            _settingsService.Store.Changed -= OnSettingsChanged;
            _window?.Hide();
            _window = null;
        }

        public void SetWallpaper(string imagePath, ScaleMode scaleMode)
        {
            _settingsService.Store.Data.WallpaperImagePath = imagePath;
            _settingsService.Store.Data.WallpaperScaleMode = scaleMode.ToString();
            _settingsService.Store.Data.WallpaperFallbackColor = _settingsService.Store.Data.WallpaperFallbackColor;
            _settingsService.Store.NotifyChanged();
        }

        private void ApplyWallpaper()
        {
            if (_window == null) return;
            var data = _settingsService.Store.Data;
            var config = new WallpaperConfig
            {
                ImagePath = data.WallpaperImagePath,
                ScaleMode = ParseScaleMode(data.WallpaperScaleMode),
                FallbackColor = data.WallpaperFallbackColor,
            };
            _window.UpdateWallpaper(config);
        }

        private void OnSettingsChanged()
        {
            GLib.Functions.IdleAdd(0, () =>
            {
                ApplyWallpaper();
                return false;
            });
        }

        private static ScaleMode ParseScaleMode(string value)
        {
            return value switch
            {
                "Fit" => ScaleMode.Fit,
                "Center" => ScaleMode.Center,
                "Stretch" => ScaleMode.Stretch,
                "Tile" => ScaleMode.Tile,
                _ => ScaleMode.Fill,
            };
        }
    }
}
