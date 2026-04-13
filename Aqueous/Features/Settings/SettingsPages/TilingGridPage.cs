using Gtk;
using static Aqueous.Features.Settings.SettingsWidgets;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class TilingGridPage
    {
        public static Gtk.Box Create(SettingsStore store)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            page.Append(SectionTitle("Tiling & Grid"));

            // Grid
            page.Append(SubSectionTitle("Grid Snapping"));
            page.Append(DurationSlider("Animation duration", "grid", "duration", 0, 1000, 50, 300));
            page.Append(DurationCurve("Animation curve", "grid", "duration", "circle"));
            page.Append(Dropdown("Animation type", "grid", "type",
                ["crossfade", "wobbly", "none"], "crossfade"));
            page.Append(Keybind("Restore", "grid", "restore", "<super> KEY_DOWN | <super> KEY_KP0"));
            page.Append(Keybind("Center", "grid", "slot_c", "<super> KEY_UP | <super> KEY_KP5"));
            page.Append(Keybind("Left", "grid", "slot_l", "<super> KEY_LEFT | <super> KEY_KP4"));
            page.Append(Keybind("Right", "grid", "slot_r", "<super> KEY_RIGHT | <super> KEY_KP6"));
            page.Append(Keybind("Top", "grid", "slot_t", "<super> KEY_KP8"));
            page.Append(Keybind("Bottom", "grid", "slot_b", "<super> KEY_KP2"));
            page.Append(Keybind("Top-left", "grid", "slot_tl", "<super> KEY_KP7"));
            page.Append(Keybind("Top-right", "grid", "slot_tr", "<super> KEY_KP9"));
            page.Append(Keybind("Bottom-left", "grid", "slot_bl", "<super> KEY_KP1"));
            page.Append(Keybind("Bottom-right", "grid", "slot_br", "<super> KEY_KP3"));

            // Simple Tile
            page.Append(SubSectionTitle("Simple Tiling"));
            page.Append(Entry("Tile by default", "simple-tile", "tile_by_default", "all"));
            page.Append(IntSlider("Inner gap size", "simple-tile", "inner_gap_size", 0, 30, 1, 5));
            page.Append(IntSlider("Outer horizontal gap", "simple-tile", "outer_horiz_gap_size", 0, 30, 1, 0));
            page.Append(IntSlider("Outer vertical gap", "simple-tile", "outer_vert_gap_size", 0, 30, 1, 0));
            page.Append(Keybind("Toggle tiling", "simple-tile", "key_toggle", "<super> KEY_T"));
            page.Append(Keybind("Focus above", "simple-tile", "key_focus_above", "<super> KEY_K"));
            page.Append(Keybind("Focus below", "simple-tile", "key_focus_below", "<super> KEY_J"));
            page.Append(Keybind("Focus left", "simple-tile", "key_focus_left", "<super> KEY_H"));
            page.Append(Keybind("Focus right", "simple-tile", "key_focus_right", "<super> KEY_L"));
            page.Append(DurationSlider("Animation duration", "simple-tile", "animation_duration", 0, 1000, 50, 0));
            page.Append(Toggle("Keep fullscreen on adjacent", "simple-tile", "keep_fullscreen_on_adjacent", true));
            page.Append(ColorPicker("Preview color", "simple-tile", "preview_base_color", "#8080FF80"));
            page.Append(ColorPicker("Preview border", "simple-tile", "preview_base_border", "#404080CC"));

            return page;
        }
    }
}
