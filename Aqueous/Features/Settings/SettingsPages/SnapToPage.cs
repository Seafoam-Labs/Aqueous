using System.Linq;
using Aqueous.Bindings.AstalGTK4.Services;
using Aqueous.Features.SnapTo;
using Gtk;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class SnapToPage
    {
        public static Gtk.Box Create(SettingsStore store, AstalApplication? app = null)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            var title = Gtk.Label.New("Snap Zones");
            title.AddCssClass("settings-section-title");
            title.Halign = Align.Start;
            page.Append(title);

            // Enable/disable toggle
            page.Append(CreateEnableRow(store));

            // Keybind
            page.Append(CreateKeybindRow(store));

            // Layout selector
            page.Append(CreateLayoutRow(store));

            // Zone preview
            page.Append(CreateZonePreview(store));

            // Edit Zones button (Option B)
            if (app != null)
            {
                var editBtn = Gtk.Button.NewWithLabel("Edit Zones");
                editBtn.AddCssClass("suggested-action");
                editBtn.Halign = Align.Start;
                editBtn.OnClicked += (_, _) =>
                {
                    var editor = new SnapToEditorPopup(app, SnapToConfig.Load());
                    editor.Show();
                };
                page.Append(editBtn);
            }

            return page;
        }

        private static Gtk.Box CreateKeybindRow(SettingsStore store)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var label = Gtk.Label.New("SnapTo keybind");
            label.Hexpand = true;
            label.Halign = Align.Start;
            row.Append(label);

            var entry = Gtk.Entry.New();
            entry.SetText(store.Data.SnapToKeybind);
            entry.SetSizeRequest(160, -1);

            var buffer = entry.GetBuffer();
            buffer.OnInsertedText += (_, _) =>
            {
                store.Data.SnapToKeybind = buffer.GetText();
                store.NotifyChanged();
            };
            buffer.OnDeletedText += (_, _) =>
            {
                store.Data.SnapToKeybind = buffer.GetText();
                store.NotifyChanged();
            };
            row.Append(entry);

            return row;
        }

        private static Gtk.Box CreateEnableRow(SettingsStore store)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var label = Gtk.Label.New("Enable snap zones");
            label.Hexpand = true;
            label.Halign = Align.Start;
            row.Append(label);

            var toggle = Gtk.Switch.New();
            toggle.Active = store.Data.SnapToEnabled;
            toggle.Valign = Align.Center;
            toggle.OnStateSet += (sender, args) =>
            {
                store.Data.SnapToEnabled = args.State;
                store.NotifyChanged();
                return false;
            };
            row.Append(toggle);

            return row;
        }

        private static Gtk.Box CreateLayoutRow(SettingsStore store)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var label = Gtk.Label.New("Active layout");
            label.Hexpand = true;
            label.Halign = Align.Start;
            row.Append(label);

            var layouts = SnapToConfig.Load();
            var names = layouts.Select(l => l.Name).ToArray();
            var options = Gtk.StringList.New(names);
            var dropdown = Gtk.DropDown.New(options, null);

            var activeIndex = System.Array.IndexOf(names, store.Data.ActiveSnapLayout);
            dropdown.Selected = activeIndex >= 0 ? (uint)activeIndex : 0u;

            dropdown.OnNotify += (sender, args) =>
            {
                if (args.Pspec.GetName() == "selected" && dropdown.Selected < names.Length)
                {
                    store.Data.ActiveSnapLayout = names[dropdown.Selected];
                    store.NotifyChanged();
                }
            };
            row.Append(dropdown);

            return row;
        }

        private static Gtk.Box CreateZonePreview(SettingsStore store)
        {
            var container = Gtk.Box.New(Orientation.Vertical, 4);
            container.AddCssClass("settings-row");

            var label = Gtk.Label.New("Zone preview");
            label.Halign = Align.Start;
            container.Append(label);

            var layouts = SnapToConfig.Load();
            var layout = layouts.FirstOrDefault(l => l.Name == store.Data.ActiveSnapLayout)
                         ?? layouts.FirstOrDefault();

            if (layout == null) return container;

            // Simple box-based zone preview
            var previewFrame = Gtk.Fixed.New();
            previewFrame.SetSizeRequest(400, 200);

            string[] colors = ["#89b4fa", "#a6e3a1", "#f38ba8", "#fab387", "#cba6f7"];
            int i = 0;
            foreach (var zone in layout.Zones)
            {
                var color = colors[i % colors.Length];
                var zoneLabel = Gtk.Label.New(zone.Name);
                zoneLabel.SetSizeRequest((int)(zone.Width * 396), (int)(zone.Height * 196));

                var cssProvider = Gtk.CssProvider.New();
                cssProvider.LoadFromString(
                    $"label {{ background-color: alpha({color}, 0.3); border: 1px solid {color}; border-radius: 4px; padding: 4px; color: #cdd6f4; font-size: 11px; }}");
                zoneLabel.GetStyleContext().AddProvider(cssProvider, Gtk.Constants.STYLE_PROVIDER_PRIORITY_APPLICATION);

                previewFrame.Put(zoneLabel, zone.X * 400 + 2, zone.Y * 200 + 2);
                i++;
            }

            container.Append(previewFrame);
            return container;
        }
    }
}
