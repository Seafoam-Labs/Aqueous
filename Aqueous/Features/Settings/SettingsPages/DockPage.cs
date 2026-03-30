using Gtk;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class DockPage
    {
        public static Gtk.Box Create(SettingsStore store)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            var title = Gtk.Label.New("Dock");
            title.AddCssClass("settings-section-title");
            title.Halign = Align.Start;
            page.Append(title);

            page.Append(CreateDockPositionRow(store));

            return page;
        }

        private static Gtk.Box CreateDockPositionRow(SettingsStore store)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var label = Gtk.Label.New("Dock position");
            label.Hexpand = true;
            label.Halign = Align.Start;
            row.Append(label);

            var options = Gtk.StringList.New(["Left", "Bottom", "Right", "Hidden"]);
            var dropdown = Gtk.DropDown.New(options, null);

            dropdown.Selected = store.Data.DockPosition switch
            {
                "Bottom" => 1u,
                "Right" => 2u,
                "Hidden" => 3u,
                _ => 0u,
            };

            dropdown.OnNotify += (sender, args) =>
            {
                if (args.Pspec.GetName() == "selected")
                {
                    store.Data.DockPosition = dropdown.Selected switch
                    {
                        1 => "Bottom",
                        2 => "Right",
                        3 => "Hidden",
                        _ => "Left",
                    };
                    store.NotifyChanged();
                }
            };

            row.Append(dropdown);
            return row;
        }
    }
}
