using Gtk;
using static Aqueous.Features.Settings.SettingsWidgets;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class CubePage
    {
        public static Gtk.Box Create(SettingsStore store)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            page.Append(SectionTitle("Desktop Cube"));

            page.Append(Keybind("Activate", "cube", "activate", "<alt> <ctrl> BTN_LEFT"));
            page.Append(Keybind("Rotate left", "cube", "rotate_left", "none"));
            page.Append(Keybind("Rotate right", "cube", "rotate_right", "none"));
            page.Append(ColorPicker("Background", "cube", "background", "#1A1A1AFF"));
            page.Append(Dropdown("Background mode", "cube", "background_mode",
                ["simple", "cubemap", "skydome"], "simple"));
            page.Append(Entry("Cubemap image", "cube", "cubemap_image"));
            page.Append(Entry("Skydome texture", "cube", "skydome_texture"));
            page.Append(Toggle("Skydome mirror", "cube", "skydome_mirror", true));
            page.Append(Dropdown("Deform", "cube", "deform",
                ["0", "1", "2"], "0"));
            page.Append(Toggle("Lighting", "cube", "light", true));
            page.Append(Slider("Zoom", "cube", "zoom", 0, 1, 0.01, 0.1));
            page.Append(Slider("Horizontal spin speed", "cube", "speed_spin_horiz", 0, 0.2, 0.005, 0.02));
            page.Append(Slider("Vertical spin speed", "cube", "speed_spin_vert", 0, 0.2, 0.005, 0.02));
            page.Append(Slider("Zoom speed", "cube", "speed_zoom", 0, 0.5, 0.01, 0.07));
            page.Append(DurationSlider("Initial animation", "cube", "initial_animation", 0, 2000, 50, 350));

            return page;
        }
    }
}
