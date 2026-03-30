namespace Aqueous.Features.Wallpaper
{
    public enum ScaleMode
    {
        Fill,
        Fit,
        Center,
        Stretch,
        Tile
    }

    public class WallpaperConfig
    {
        public string ImagePath { get; set; } = "";
        public ScaleMode ScaleMode { get; set; } = ScaleMode.Fill;
        public string FallbackColor { get; set; } = "#1e1e2e";
    }
}
