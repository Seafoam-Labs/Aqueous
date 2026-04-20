using System;
using System.IO;
using Gtk;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class GeneralPage
    {
        private static readonly string AutostartDir =
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".config", "autostart");

        private static readonly string AutostartFile =
            Path.Combine(AutostartDir, "aqueous.desktop");

        public static Gtk.Box Create(SettingsStore store)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            var title = Gtk.Label.New("General");
            title.AddCssClass("settings-section-title");
            title.Halign = Align.Start;
            page.Append(title);

            // Autostart toggle
            page.Append(CreateAutostartRow(store));

            // Bar position
            page.Append(CreateBarPositionRow(store));

            // Accent color
            page.Append(CreateAccentColorRow(store));

            // Panel Opacity
            page.Append(CreatePanelOpacityRow(store));

            // Advanced INI Keys
            page.Append(CreateAdvancedIniKeysRow(store));

            return page;
        }

        private static Gtk.Box CreatePanelOpacityRow(SettingsStore store)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var label = Gtk.Label.New("Panel opacity");
            label.Hexpand = true;
            label.Halign = Align.Start;
            row.Append(label);

            var scale = Gtk.Scale.NewWithRange(Orientation.Horizontal, 0.1, 1.0, 0.05);
            scale.WidthRequest = 200;
            scale.DrawValue = true;
            scale.SetValue(store.Data.PanelOpacity);
            
            scale.OnChangeValue += (_, args) =>
            {
                store.Data.PanelOpacity = args.Value;
                store.NotifyChanged();
                return false;
            };

            row.Append(scale);
            return row;
        }

        private static Gtk.Box CreateAdvancedIniKeysRow(SettingsStore store)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var label = Gtk.Label.New("Show Advanced INI Keys");
            label.Hexpand = true;
            label.Halign = Align.Start;
            row.Append(label);

            var toggle = Gtk.Switch.New();
            toggle.Active = store.Data.ShowAdvancedIniKeys;
            toggle.Valign = Align.Center;
            toggle.OnStateSet += (sender, args) =>
            {
                store.Data.ShowAdvancedIniKeys = args.State;
                store.NotifyChanged();
                return false;
            };
            row.Append(toggle);

            return row;
        }

        private static Gtk.Box CreateAutostartRow(SettingsStore store)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var label = Gtk.Label.New("Launch at startup");
            label.Hexpand = true;
            label.Halign = Align.Start;
            row.Append(label);

            var toggle = Gtk.Switch.New();
            toggle.Active = store.Data.AutostartEnabled;
            toggle.Valign = Align.Center;
            toggle.OnStateSet += (sender, args) =>
            {
                store.Data.AutostartEnabled = args.State;
                UpdateAutostartFile(args.State);
                store.NotifyChanged();
                return false;
            };
            row.Append(toggle);

            return row;
        }

        private static Gtk.Box CreateBarPositionRow(SettingsStore store)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var label = Gtk.Label.New("Bar position");
            label.Hexpand = true;
            label.Halign = Align.Start;
            row.Append(label);

            var options = Gtk.StringList.New(["Top", "Bottom"]);
            var dropdown = Gtk.DropDown.New(options, null);
            dropdown.Selected = store.Data.BarPosition == "Bottom" ? 1u : 0u;
            dropdown.OnNotify += (sender, args) =>
            {
                if (args.Pspec.GetName() == "selected")
                {
                    store.Data.BarPosition = dropdown.Selected == 1 ? "Bottom" : "Top";
                    store.NotifyChanged();
                }
            };
            row.Append(dropdown);

            return row;
        }

        private static Gtk.Box CreateAccentColorRow(SettingsStore store)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var label = Gtk.Label.New("Accent color");
            label.Hexpand = true;
            label.Halign = Align.Start;
            row.Append(label);

            string[] presets = ["#89b4fa", "#a6e3a1", "#f38ba8", "#fab387", "#cba6f7", "#f9e2af"];
            var colorBox = Gtk.Box.New(Orientation.Horizontal, 4);
            int colorIndex = 0;
            foreach (var color in presets)
            {
                var btn = Gtk.Button.New();
                btn.AddCssClass("settings-color-btn");

                var uniqueClass = $"accent-color-{colorIndex}";
                btn.AddCssClass(uniqueClass);
                btn.SetSizeRequest(28, 28);

                var cssProvider = Gtk.CssProvider.New();
                cssProvider.LoadFromString($".{uniqueClass} {{ background-color: {color}; border-radius: 14px; min-width: 28px; min-height: 28px; }}");
                Gtk.StyleContext.AddProviderForDisplay(
                    Gdk.Display.GetDefault()!,
                    cssProvider,
                    Gtk.Constants.STYLE_PROVIDER_PRIORITY_APPLICATION);

                var c = color;
                btn.OnClicked += (_, _) =>
                {
                    store.Data.ThemeAccentColor = c;
                    store.NotifyChanged();
                };
                colorBox.Append(btn);
                colorIndex++;
            }
            row.Append(colorBox);

            return row;
        }

        private static void UpdateAutostartFile(bool enabled)
        {
            try
            {
                if (enabled)
                {
                    Directory.CreateDirectory(AutostartDir);
                    var content = "[Desktop Entry]\nType=Application\nName=Aqueous\nExec=aqueous\nX-GNOME-Autostart-enabled=true\n";
                    File.WriteAllText(AutostartFile, content);
                }
                else
                {
                    if (File.Exists(AutostartFile))
                        File.Delete(AutostartFile);
                }
            }
            catch
            {
                // Ignore autostart file errors
            }
        }
    }
}
