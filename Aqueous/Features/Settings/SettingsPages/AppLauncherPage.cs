using Gtk;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class AppLauncherPage
    {
        public static Gtk.Box Create(SettingsStore store)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            var title = Gtk.Label.New("App Launcher");
            title.AddCssClass("settings-section-title");
            title.Halign = Align.Start;
            page.Append(title);

            // Keybind
            page.Append(CreateKeybindRow(store));

            // Max results
            page.Append(CreateMaxResultsRow(store));

            return page;
        }

        private static Gtk.Box CreateKeybindRow(SettingsStore store)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var label = Gtk.Label.New("Launch keybind");
            label.Hexpand = true;
            label.Halign = Align.Start;
            row.Append(label);

            var entry = Gtk.Entry.New();
            entry.SetText(store.Data.LaunchKeybind);
            entry.SetSizeRequest(160, -1);

            var buffer = entry.GetBuffer();
            buffer.OnInsertedText += (_, _) =>
            {
                store.Data.LaunchKeybind = buffer.GetText();
                store.NotifyChanged();
            };
            buffer.OnDeletedText += (_, _) =>
            {
                store.Data.LaunchKeybind = buffer.GetText();
                store.NotifyChanged();
            };
            row.Append(entry);

            return row;
        }

        private static Gtk.Box CreateMaxResultsRow(SettingsStore store)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var label = Gtk.Label.New("Max results");
            label.Hexpand = true;
            label.Halign = Align.Start;
            row.Append(label);

            var spin = Gtk.SpinButton.NewWithRange(5, 50, 1);
            spin.Value = store.Data.MaxResults;
            spin.OnValueChanged += (_, _) =>
            {
                store.Data.MaxResults = (int)spin.Value;
                store.NotifyChanged();
            };
            row.Append(spin);

            return row;
        }
    }
}
