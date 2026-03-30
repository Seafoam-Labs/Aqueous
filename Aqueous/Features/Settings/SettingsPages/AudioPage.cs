using Gtk;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class AudioPage
    {
        public static Gtk.Box Create(SettingsStore store)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            var title = Gtk.Label.New("Audio");
            title.AddCssClass("settings-section-title");
            title.Halign = Align.Start;
            page.Append(title);

            // Volume step
            page.Append(CreateVolumeStepRow(store));

            // Show tray widget
            page.Append(CreateTrayToggleRow(store));

            return page;
        }

        private static Gtk.Box CreateVolumeStepRow(SettingsStore store)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var label = Gtk.Label.New("Volume step (%)");
            label.Hexpand = true;
            label.Halign = Align.Start;
            row.Append(label);

            var slider = Gtk.Scale.NewWithRange(Orientation.Horizontal, 1, 10, 1);
            slider.SetValue(store.Data.VolumeStep);
            slider.SetSizeRequest(200, -1);
            slider.OnChangeValue += (scale, args) =>
            {
                store.Data.VolumeStep = (int)args.Value;
                store.NotifyChanged();
                return false;
            };
            row.Append(slider);

            return row;
        }

        private static Gtk.Box CreateTrayToggleRow(SettingsStore store)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var label = Gtk.Label.New("Show tray widget");
            label.Hexpand = true;
            label.Halign = Align.Start;
            row.Append(label);

            var toggle = Gtk.Switch.New();
            toggle.Active = store.Data.ShowTrayWidget;
            toggle.Valign = Align.Center;
            toggle.OnStateSet += (sender, args) =>
            {
                store.Data.ShowTrayWidget = args.State;
                store.NotifyChanged();
                return false;
            };
            row.Append(toggle);

            return row;
        }
    }
}
