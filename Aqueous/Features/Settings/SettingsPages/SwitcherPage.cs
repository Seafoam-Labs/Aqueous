using Gtk;
using static Aqueous.Features.Settings.SettingsWidgets;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class SwitcherPage
    {
        public static Gtk.Box Create(SettingsStore store)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            page.Append(SectionTitle("Window Switcher"));

            // Switcher
            page.Append(SubSectionTitle("Alt-Tab Switcher"));
            page.Append(Keybind("Next view", "switcher", "next_view", "<alt> KEY_TAB"));
            page.Append(Keybind("Previous view", "switcher", "prev_view", "<alt> <shift> KEY_TAB"));
            page.Append(DurationSlider("Speed", "switcher", "speed", 0, 2000, 50, 500));
            page.Append(IntSlider("Thumbnail rotation", "switcher", "view_thumbnail_rotation", 0, 90, 1, 30));
            page.Append(Slider("Thumbnail scale", "switcher", "view_thumbnail_scale", 0.1, 3, 0.1, 1));

            // Fast switcher
            page.Append(SubSectionTitle("Fast Switcher"));
            page.Append(Keybind("Activate", "fast-switcher", "activate", "<alt> KEY_ESC"));
            page.Append(Keybind("Activate backward", "fast-switcher", "activate_backward", "<alt> <shift> KEY_ESC"));
            page.Append(Slider("Inactive alpha", "fast-switcher", "inactive_alpha", 0, 1, 0.05, 0.7));

            // Scale (task view)
            page.Append(SubSectionTitle("Scale (Task View)"));
            page.Append(Keybind("Toggle", "scale", "toggle", "<super> KEY_P"));
            page.Append(Keybind("Toggle all", "scale", "toggle_all"));
            page.Append(DurationSlider("Duration", "scale", "duration", 0, 2000, 50, 750));
            page.Append(IntSlider("Spacing", "scale", "spacing", 0, 200, 5, 50));
            page.Append(Slider("Inactive alpha", "scale", "inactive_alpha", 0, 1, 0.05, 0.75));
            page.Append(Toggle("Include minimized", "scale", "include_minimized"));
            page.Append(Slider("Minimized alpha", "scale", "minimized_alpha", 0, 1, 0.05, 0.45));
            page.Append(Toggle("Allow zoom", "scale", "allow_zoom"));
            page.Append(Toggle("Middle click close", "scale", "middle_click_close"));
            page.Append(Toggle("Close on new view", "scale", "close_on_new_view"));
            page.Append(Dropdown("Title overlay", "scale", "title_overlay",
                ["all", "mouse", "none"], "all"));
            page.Append(Dropdown("Title position", "scale", "title_position",
                ["center", "above", "below"], "center"));
            page.Append(IntSlider("Title font size", "scale", "title_font_size", 8, 48, 1, 16));
            page.Append(ColorPicker("Background color", "scale", "bg_color", "#1A1A1AE6"));
            page.Append(ColorPicker("Text color", "scale", "text_color", "#CCCCCCFF"));
            page.Append(IntSlider("Outer margin", "scale", "outer_margin", 0, 100, 1, 0));

            // Scale title filter
            page.Append(SubSectionTitle("Scale Title Filter"));
            page.Append(IntSlider("Font size", "scale-title-filter", "font_size", 8, 72, 1, 30));
            page.Append(Toggle("Case sensitive", "scale-title-filter", "case_sensitive"));
            page.Append(Toggle("Overlay", "scale-title-filter", "overlay", true));
            page.Append(Toggle("Share filter", "scale-title-filter", "share_filter"));
            page.Append(ColorPicker("Background color", "scale-title-filter", "bg_color", "#00000080"));
            page.Append(ColorPicker("Text color", "scale-title-filter", "text_color", "#CCCCCCCC"));

            return page;
        }
    }
}
