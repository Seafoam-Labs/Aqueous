using Gtk;
using static Aqueous.Features.Settings.SettingsWidgets;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class WorkspacePage
    {
        public static Gtk.Box Create(SettingsStore store)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            page.Append(SectionTitle("Workspaces"));

            // Virtual desktop size
            page.Append(SubSectionTitle("Virtual Desktop"));
            page.Append(IntSlider("Horizontal workspaces", "core", "vwidth", 1, 10, 1, 3));
            page.Append(IntSlider("Vertical workspaces", "core", "vheight", 1, 10, 1, 3));

            // VSwitch
            page.Append(SubSectionTitle("Workspace Switching"));
            page.Append(Keybind("Switch up", "vswitch", "binding_up", "<alt> <super> KEY_UP"));
            page.Append(Keybind("Switch down", "vswitch", "binding_down", "<alt> <super> KEY_DOWN"));
            page.Append(Keybind("Switch left", "vswitch", "binding_left", "<alt> <super> KEY_LEFT"));
            page.Append(Keybind("Switch right", "vswitch", "binding_right", "<alt> <super> KEY_RIGHT"));
            page.Append(Keybind("With window left", "vswitch", "with_win_left", "<alt> <shift> <super> KEY_LEFT"));
            page.Append(Keybind("With window right", "vswitch", "with_win_right", "<alt> <shift> <super> KEY_RIGHT"));
            page.Append(Keybind("With window up", "vswitch", "with_win_up", "<alt> <shift> <super> KEY_UP"));
            page.Append(Keybind("With window down", "vswitch", "with_win_down"));
            page.Append(Keybind("Send window left", "vswitch", "send_win_left"));
            page.Append(Keybind("Send window right", "vswitch", "send_win_right"));
            page.Append(Keybind("Send window up", "vswitch", "send_win_up"));
            page.Append(Keybind("Send window down", "vswitch", "send_win_down"));
            page.Append(DurationSlider("Duration", "vswitch", "duration", 0, 1000, 50, 300));
            page.Append(IntSlider("Gap", "vswitch", "gap", 0, 100, 1, 20));
            page.Append(Toggle("Wraparound", "vswitch", "wraparound"));
            page.Append(ColorPicker("Background", "vswitch", "background", "#1A1A1AFF"));

            // VSwipe
            page.Append(SubSectionTitle("Gesture Swiping"));
            page.Append(IntSlider("Fingers", "vswipe", "fingers", 3, 5, 1, 4));
            page.Append(Toggle("Enable horizontal", "vswipe", "enable_horizontal", true));
            page.Append(Toggle("Enable vertical", "vswipe", "enable_vertical", true));
            page.Append(Toggle("Enable free movement", "vswipe", "enable_free_movement"));
            page.Append(Toggle("Enable smooth transition", "vswipe", "enable_smooth_transition"));
            page.Append(DurationSlider("Duration", "vswipe", "duration", 0, 1000, 50, 180));
            page.Append(Slider("Gap", "vswipe", "gap", 0, 100, 1, 32));
            page.Append(Slider("Threshold", "vswipe", "threshold", 0, 1, 0.05, 0.35));
            page.Append(Slider("Speed cap", "vswipe", "speed_cap", 0, 1, 0.01, 0.05));

            // Expo
            page.Append(SubSectionTitle("Expo (Workspace Overview)"));
            page.Append(Keybind("Toggle expo", "expo", "toggle", "<super> KEY_E"));
            page.Append(DurationSlider("Duration", "expo", "duration", 0, 1000, 50, 300));
            page.Append(ColorPicker("Background", "expo", "background", "#1A1A1AFF"));
            page.Append(Slider("Inactive brightness", "expo", "inactive_brightness", 0, 1, 0.05, 0.7));
            page.Append(IntSlider("Offset", "expo", "offset", 0, 100, 1, 10));
            page.Append(Toggle("Keyboard interaction", "expo", "keyboard_interaction", true));

            // Workspace names
            page.Append(SubSectionTitle("Workspace Names"));
            page.Append(Entry("Font", "workspace-names", "font", "sans-serif"));
            page.Append(Dropdown("Position", "workspace-names", "position",
                ["center", "top_left", "top_center", "top_right", "bottom_left", "bottom_center", "bottom_right"], "center"));
            page.Append(IntSlider("Display duration", "workspace-names", "display_duration", 100, 5000, 100, 500));
            page.Append(ColorPicker("Background color", "workspace-names", "background_color", "#333333B3"));
            page.Append(ColorPicker("Text color", "workspace-names", "text_color", "#FFFFFFFF"));
            page.Append(Slider("Background radius", "workspace-names", "background_radius", 0, 60, 1, 30));

            // Workspace sets
            page.Append(SubSectionTitle("Workspace Sets"));
            page.Append(DurationSlider("Label duration", "wsets", "label_duration", 0, 5000, 100, 2000));

            // Output switching
            page.Append(SubSectionTitle("Output Switching"));
            page.Append(Keybind("Next output", "oswitch", "next_output", "<super> KEY_O"));
            page.Append(Keybind("Next output with window", "oswitch", "next_output_with_win", "<shift> <super> KEY_O"));
            page.Append(Keybind("Previous output", "oswitch", "prev_output"));
            page.Append(Keybind("Previous output with window", "oswitch", "prev_output_with_win"));

            return page;
        }
    }
}
