using System;
using System.IO;
using Aqueous.Bindings.AstalGTK4;
using Aqueous.Bindings.AstalGTK4.Services;
using Gtk;

namespace Aqueous.Features.Wallpaper
{
    public class WallpaperWindow
    {
        private readonly AstalApplication _app;
        private AstalWindow? _window;
        private Gtk.Picture? _picture;
        private Gtk.Box? _container;

        public WallpaperWindow(AstalApplication app)
        {
            _app = app;
        }

        public void Show()
        {
            _window = new AstalWindow();
            _app.GtkApplication.AddWindow(_window.GtkWindow);
            _window.Namespace = "wallpaper";
            _window.Layer = AstalLayer.ASTAL_LAYER_BACKGROUND;
            _window.Exclusivity = AstalExclusivity.ASTAL_EXCLUSIVITY_NORMAL;
            _window.Anchor = AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_TOP
                           | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_BOTTOM
                           | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_LEFT
                           | AstalWindowAnchor.ASTAL_WINDOW_ANCHOR_RIGHT;

            _window.GtkWindow.AddCssClass("wallpaper-window");

            _container = Gtk.Box.New(Orientation.Vertical, 0);
            _container.AddCssClass("wallpaper-container");
            _container.Hexpand = true;
            _container.Vexpand = true;

            _picture = Gtk.Picture.New();
            _picture.AddCssClass("wallpaper-image");
            _picture.Hexpand = true;
            _picture.Vexpand = true;
            _picture.SetCanShrink(true);
            _picture.ContentFit = ContentFit.Cover;

            _container.Append(_picture);
            _window.GtkWindow.SetChild(_container);
            _window.GtkWindow.Present();
        }

        public void Hide()
        {
            if (_window != null)
            {
                _window.GtkWindow.Close();
                _window = null;
                _picture = null;
                _container = null;
            }
        }

        public void UpdateWallpaper(WallpaperConfig config)
        {
            if (_picture == null || _container == null) return;

            var imagePath = config.ImagePath;
            if (string.IsNullOrEmpty(imagePath))
            {
                imagePath = Path.Combine(AppContext.BaseDirectory, "Features", "Wallpaper", "DefaultWallpapers", "Moon.png");
            }
            else if (!Path.IsPathRooted(imagePath))
            {
                imagePath = Path.Combine(AppContext.BaseDirectory, imagePath);
            }

            if (File.Exists(imagePath))
            {
                try
                {
                    var texture = Gdk.Texture.NewFromFilename(imagePath);
                    _picture.SetPaintable(texture);
                    _picture.SetVisible(true);
                }
                catch
                {
                    _picture.SetVisible(false);
                }
            }
            else
            {
                _picture.SetVisible(false);
            }

            // Apply scale mode
            _picture.ContentFit = config.ScaleMode switch
            {
                ScaleMode.Fill => ContentFit.Cover,
                ScaleMode.Fit => ContentFit.Contain,
                ScaleMode.Stretch => ContentFit.Fill,
                ScaleMode.Center => ContentFit.ScaleDown,
                ScaleMode.Tile => ContentFit.Cover, // Tile not natively supported, fallback to cover
                _ => ContentFit.Cover,
            };
        }
    }
}
