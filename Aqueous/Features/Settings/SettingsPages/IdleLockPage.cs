using Gtk;
using static Aqueous.Features.Settings.SettingsWidgets;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class IdleLockPage
    {
        public static Gtk.Box Create(SettingsStore store)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            page.Append(SectionTitle("Idle & Lock"));

            page.Append(IntSlider("Screensaver timeout (s)", "idle", "screensaver_timeout", 0, 7200, 60, 3600));
            page.Append(IntSlider("DPMS timeout (s)", "idle", "dpms_timeout", -1, 7200, 60, -1));
            page.Append(Toggle("Disable on fullscreen", "idle", "disable_on_fullscreen", true));
            page.Append(Toggle("Disable initially", "idle", "disable_initially"));
            page.Append(Keybind("Toggle idle", "idle", "toggle", "none"));

            page.Append(SubSectionTitle("Idle Cube Animation"));
            page.Append(Slider("Cube max zoom", "idle", "cube_max_zoom", 1, 5, 0.1, 1.5));
            page.Append(Slider("Cube rotate speed", "idle", "cube_rotate_speed", 0.1, 5, 0.1, 1));
            page.Append(IntSlider("Cube zoom speed", "idle", "cube_zoom_speed", 100, 5000, 100, 1000));

            return page;
        }
    }
}
