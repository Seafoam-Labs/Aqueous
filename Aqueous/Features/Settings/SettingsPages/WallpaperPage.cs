using Gtk;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class WallpaperPage
    {
        public static Gtk.Box Create(SettingsStore store)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            var title = Gtk.Label.New("Wallpaper");
            title.AddCssClass("settings-section-title");
            title.Halign = Align.Start;
            page.Append(title);

            page.Append(CreateImagePathRow(store));
            page.Append(CreateScaleModeRow(store));
            page.Append(CreateFallbackColorRow(store));

            return page;
        }

        private static Gtk.Box CreateImagePathRow(SettingsStore store)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var label = Gtk.Label.New("Image path");
            label.Hexpand = true;
            label.Halign = Align.Start;
            row.Append(label);

            var entry = Gtk.Entry.New();
            var buffer = entry.GetBuffer();
            buffer.SetText(store.Data.WallpaperImagePath, -1);
            entry.SetSizeRequest(300, -1);

            entry.OnActivate += (_, _) =>
            {
                store.Data.WallpaperImagePath = buffer.GetText();
                store.NotifyChanged();
            };

            row.Append(entry);

            var applyBtn = Gtk.Button.NewWithLabel("Apply");
            applyBtn.OnClicked += (_, _) =>
            {
                store.Data.WallpaperImagePath = buffer.GetText();
                store.NotifyChanged();
            };
            row.Append(applyBtn);

            return row;
        }

        private static Gtk.Box CreateScaleModeRow(SettingsStore store)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var label = Gtk.Label.New("Scale mode");
            label.Hexpand = true;
            label.Halign = Align.Start;
            row.Append(label);

            var options = Gtk.StringList.New(["Fill", "Fit", "Center", "Stretch", "Tile"]);
            var dropdown = Gtk.DropDown.New(options, null);

            dropdown.Selected = store.Data.WallpaperScaleMode switch
            {
                "Fit" => 1u,
                "Center" => 2u,
                "Stretch" => 3u,
                "Tile" => 4u,
                _ => 0u,
            };

            dropdown.OnNotify += (sender, args) =>
            {
                if (args.Pspec.GetName() == "selected")
                {
                    store.Data.WallpaperScaleMode = dropdown.Selected switch
                    {
                        1 => "Fit",
                        2 => "Center",
                        3 => "Stretch",
                        4 => "Tile",
                        _ => "Fill",
                    };
                    store.NotifyChanged();
                }
            };

            row.Append(dropdown);
            return row;
        }

        private static Gtk.Box CreateFallbackColorRow(SettingsStore store)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var label = Gtk.Label.New("Fallback color");
            label.Hexpand = true;
            label.Halign = Align.Start;
            row.Append(label);

            var entry = Gtk.Entry.New();
            var buffer = entry.GetBuffer();
            buffer.SetText(store.Data.WallpaperFallbackColor, -1);
            entry.SetSizeRequest(150, -1);

            entry.OnActivate += (_, _) =>
            {
                store.Data.WallpaperFallbackColor = buffer.GetText();
                store.NotifyChanged();
            };

            row.Append(entry);
            return row;
        }
    }
}
