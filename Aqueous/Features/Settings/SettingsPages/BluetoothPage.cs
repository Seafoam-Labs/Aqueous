using Gtk;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class BluetoothPage
    {
        public static Gtk.Box Create(SettingsStore store)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            var title = Gtk.Label.New("Bluetooth");
            title.AddCssClass("settings-section-title");
            title.Halign = Align.Start;
            page.Append(title);

            // Show tray widget
            page.Append(CreateTrayToggleRow(store));

            // Auto-connect trusted devices
            page.Append(CreateAutoConnectRow(store));

            return page;
        }

        private static Gtk.Box CreateTrayToggleRow(SettingsStore store)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var label = Gtk.Label.New("Show Bluetooth tray widget");
            label.Hexpand = true;
            label.Halign = Align.Start;
            row.Append(label);

            var toggle = Gtk.Switch.New();
            toggle.Active = store.Data.ShowBluetoothTray;
            toggle.Valign = Align.Center;
            toggle.OnStateSet += (sender, args) =>
            {
                store.Data.ShowBluetoothTray = args.State;
                store.NotifyChanged();
                return false;
            };
            row.Append(toggle);

            return row;
        }

        private static Gtk.Box CreateAutoConnectRow(SettingsStore store)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var label = Gtk.Label.New("Auto-connect trusted devices");
            label.Hexpand = true;
            label.Halign = Align.Start;
            row.Append(label);

            var toggle = Gtk.Switch.New();
            toggle.Active = store.Data.BluetoothAutoConnect;
            toggle.Valign = Align.Center;
            toggle.OnStateSet += (sender, args) =>
            {
                store.Data.BluetoothAutoConnect = args.State;
                store.NotifyChanged();
                return false;
            };
            row.Append(toggle);

            return row;
        }
    }
}
