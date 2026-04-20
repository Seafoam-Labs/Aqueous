using Gtk;
using Aqueous.Features.Corners;
using static Aqueous.Features.Settings.SettingsWidgets;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class DecorationsPage
    {
        public static Gtk.Box Create(SettingsStore store)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            page.Append(SectionTitle("Decorations"));

            // Server-side decoration
            page.Append(SubSectionTitle("Server-Side Decoration"));
            page.Append(ColorPicker("Active color", "decoration", "active_color", "#222222AA"));
            page.Append(ColorPicker("Inactive color", "decoration", "inactive_color", "#333333DD"));
            page.Append(IntSlider("Border size", "decoration", "border_size", 0, 20, 1, 4));
            page.Append(IntSlider("Title height", "decoration", "title_height", 0, 60, 1, 30));
            page.Append(Entry("Font", "decoration", "font", "MonoLisa Script, sans-serif"));
            page.Append(ColorPicker("Font color", "decoration", "font_color", "#FFFFFFFF"));
            page.Append(Entry("Button order", "decoration", "button_order", "minimize maximize close"));
            page.Append(Dropdown("Preferred decoration mode", "core", "preferred_decoration_mode",
                ["client", "server"], "client"));

            // WinShadows
            page.Append(SubSectionTitle("Window Shadows"));
            page.Append(ColorPicker("Shadow color", "winshadows", "shadow_color", "#00000070"));
            page.Append(IntSlider("Shadow radius", "winshadows", "shadow_radius", 0, 100, 1, 40));
            page.Append(IntSlider("Horizontal offset", "winshadows", "horizontal_offset", -50, 50, 1, 0));
            page.Append(IntSlider("Vertical offset", "winshadows", "vertical_offset", -50, 50, 1, 5));
            page.Append(Toggle("Glow enabled", "winshadows", "glow_enabled"));
            page.Append(ColorPicker("Glow color", "winshadows", "glow_color", "#1C71D8FF"));
            page.Append(Slider("Glow intensity", "winshadows", "glow_intensity", 0, 1, 0.1, 0.6));
            page.Append(Slider("Glow emissivity", "winshadows", "glow_emissivity", 0, 2, 0.1, 1));
            page.Append(IntSlider("Glow spread", "winshadows", "glow_spread", 0, 50, 1, 10));
            page.Append(Toggle("Clip shadow inside", "winshadows", "clip_shadow_inside", true));

            // Corner Rounding (Vulkan-compatible)
            page.Append(SubSectionTitle("Corner Rounding"));
            page.Append(CreateCornersToggle(store));
            page.Append(IntSlider("Corner radius", "aqueous-corners", "corner_radius", 0, 30, 1, 12));
            page.Append(ColorPicker("Corner color", "aqueous-corners", "corner_color", "#1A1A1AFF"));
            page.Append(Toggle("Exclude maximized", "aqueous-corners", "exclude_maximized", true));

            return page;
        }

        private static Gtk.Box CreateCornersToggle(SettingsStore store)
        {
            var box = Gtk.Box.New(Orientation.Horizontal, 8);
            box.AddCssClass("settings-row");

            var label = Gtk.Label.New("Enable rounded corners (all windows)");
            label.Halign = Align.Start;
            label.Hexpand = true;
            box.Append(label);

            var toggle = Gtk.Switch.New();
            toggle.Active = store.Data.CornersEnabled;
            toggle.OnStateSet += (sender, args) =>
            {
                store.Data.CornersEnabled = args.State;
                _ = CornersService.Instance.SetEnabled(args.State);
                store.NotifyChanged();
                return true;
            };
            box.Append(toggle);

            return box;
        }
    }
}
