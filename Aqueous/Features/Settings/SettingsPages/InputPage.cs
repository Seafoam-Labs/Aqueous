using Gtk;
using static Aqueous.Features.Settings.SettingsWidgets;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class InputPage
    {
        public static Gtk.Box Create(SettingsStore store)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            page.Append(SectionTitle("Input"));

            // Mouse
            page.Append(SubSectionTitle("Mouse"));
            page.Append(Slider("Mouse speed", "input", "mouse_cursor_speed", -1, 1, 0.1, 0));
            page.Append(Dropdown("Mouse accel profile", "input", "mouse_accel_profile",
                ["default", "none", "flat", "adaptive"], "default"));
            page.Append(Toggle("Mouse natural scroll", "input", "mouse_natural_scroll"));
            page.Append(Slider("Mouse scroll speed", "input", "mouse_scroll_speed", 0.1, 10, 0.1, 1));

            // Touchpad
            page.Append(SubSectionTitle("Touchpad"));
            page.Append(Slider("Touchpad speed", "input", "touchpad_cursor_speed", -1, 1, 0.1, 0));
            page.Append(Dropdown("Touchpad accel profile", "input", "touchpad_accel_profile",
                ["default", "none", "flat", "adaptive"], "default"));
            page.Append(Toggle("Natural scroll", "input", "natural_scroll"));
            page.Append(Slider("Touchpad scroll speed", "input", "touchpad_scroll_speed", 0.1, 10, 0.1, 1));
            page.Append(Toggle("Tap to click", "input", "tap_to_click", true));
            page.Append(Toggle("Tap and drag", "input", "tap_and_drag", true));
            page.Append(Toggle("Drag lock", "input", "drag_lock"));
            page.Append(Toggle("Disable while typing", "input", "disable_touchpad_while_typing"));
            page.Append(Toggle("Disable while mouse", "input", "disable_touchpad_while_mouse"));
            page.Append(Toggle("Left-handed mode", "input", "left_handed_mode"));

            // Keyboard
            page.Append(SubSectionTitle("Keyboard"));
            page.Append(IntSlider("Repeat rate", "input", "kb_repeat_rate", 1, 100, 1, 40));
            page.Append(IntSlider("Repeat delay", "input", "kb_repeat_delay", 100, 1000, 50, 400));
            page.Append(Entry("Keyboard layout", "input", "xkb_layout", "us"));
            page.Append(Entry("Keyboard variant", "input", "xkb_variant"));
            page.Append(Entry("Keyboard options", "input", "xkb_options"));

            // Cursor
            page.Append(SubSectionTitle("Cursor"));
            page.Append(IntSlider("Cursor size", "input", "cursor_size", 16, 64, 2, 24));
            page.Append(Entry("Cursor theme", "input", "cursor_theme", "default"));

            // Hide cursor
            page.Append(SubSectionTitle("Hide Cursor"));
            page.Append(IntSlider("Hide delay (ms)", "hide-cursor", "hide_delay", 500, 10000, 500, 2000));
            page.Append(Keybind("Toggle hide cursor", "hide-cursor", "toggle"));

            // Auto-rotation
            page.Append(SubSectionTitle("Auto-Rotation"));
            page.Append(Toggle("Lock rotation", "autorotate-iio", "lock_rotation"));

            return page;
        }
    }
}
