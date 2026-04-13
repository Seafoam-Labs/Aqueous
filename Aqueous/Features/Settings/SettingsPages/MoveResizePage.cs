using Gtk;
using static Aqueous.Features.Settings.SettingsWidgets;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class MoveResizePage
    {
        public static Gtk.Box Create(SettingsStore store)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            page.Append(SectionTitle("Move & Resize"));

            // Move
            page.Append(SubSectionTitle("Move"));
            page.Append(Keybind("Activate", "move", "activate", "<super> BTN_LEFT"));
            page.Append(Toggle("Enable snap", "move", "enable_snap", true));
            page.Append(Toggle("Enable snap off", "move", "enable_snap_off", true));
            page.Append(IntSlider("Snap threshold", "move", "snap_threshold", 1, 100, 1, 10));
            page.Append(IntSlider("Quarter snap threshold", "move", "quarter_snap_threshold", 1, 200, 1, 50));
            page.Append(IntSlider("Snap off threshold", "move", "snap_off_threshold", 1, 100, 1, 10));
            page.Append(ColorPicker("Preview color", "move", "preview_base_color", "#8080FF80"));
            page.Append(ColorPicker("Preview border", "move", "preview_base_border", "#404080CC"));
            page.Append(IntSlider("Preview border width", "move", "preview_border_width", 0, 10, 1, 3));
            page.Append(Toggle("Join views", "move", "join_views"));

            // Resize
            page.Append(SubSectionTitle("Resize"));
            page.Append(Keybind("Activate", "resize", "activate", "<super> BTN_RIGHT"));
            page.Append(Keybind("Activate (preserve aspect)", "resize", "activate_preserve_aspect", "none"));

            // Placement
            page.Append(SubSectionTitle("Window Placement"));
            page.Append(Dropdown("Placement mode", "place", "mode",
                ["center", "cascade", "random"], "center"));

            // WM Actions
            page.Append(SubSectionTitle("Window Actions"));
            page.Append(Keybind("Minimize", "wm-actions", "minimize", "none"));
            page.Append(Keybind("Toggle maximize", "wm-actions", "toggle_maximize", "none"));
            page.Append(Keybind("Toggle fullscreen", "wm-actions", "toggle_fullscreen", "none"));
            page.Append(Keybind("Toggle always-on-top", "wm-actions", "toggle_always_on_top", "none"));
            page.Append(Keybind("Toggle sticky", "wm-actions", "toggle_sticky", "none"));
            page.Append(Keybind("Toggle show desktop", "wm-actions", "toggle_showdesktop", "none"));
            page.Append(Keybind("Send to back", "wm-actions", "send_to_back", "none"));

            // Force fullscreen
            page.Append(SubSectionTitle("Force Fullscreen"));
            page.Append(Keybind("Toggle fullscreen", "force-fullscreen", "key_toggle_fullscreen", "<alt> <super> KEY_F"));
            page.Append(Toggle("Preserve aspect ratio", "force-fullscreen", "preserve_aspect", true));
            page.Append(Toggle("Constrain pointer", "force-fullscreen", "constrain_pointer"));

            return page;
        }
    }
}
