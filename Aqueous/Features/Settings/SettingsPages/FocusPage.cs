using Gtk;
using static Aqueous.Features.Settings.SettingsWidgets;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class FocusPage
    {
        public static Gtk.Box Create(SettingsStore store)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            page.Append(SectionTitle("Focus Behavior"));

            // Focus change
            page.Append(SubSectionTitle("Directional Focus"));
            page.Append(Keybind("Focus up", "focus-change", "up", "<shift> <super> KEY_UP"));
            page.Append(Keybind("Focus down", "focus-change", "down", "<shift> <super> KEY_DOWN"));
            page.Append(Keybind("Focus left", "focus-change", "left", "<shift> <super> KEY_LEFT"));
            page.Append(Keybind("Focus right", "focus-change", "right", "<shift> <super> KEY_RIGHT"));
            page.Append(Toggle("Cross output", "focus-change", "cross-output"));
            page.Append(Toggle("Cross workspace", "focus-change", "cross-workspace"));
            page.Append(Toggle("Raise on change", "focus-change", "raise-on-change", true));
            page.Append(IntSlider("Grace up", "focus-change", "grace-up", 0, 20, 1, 1));
            page.Append(IntSlider("Grace down", "focus-change", "grace-down", 0, 20, 1, 1));
            page.Append(IntSlider("Grace left", "focus-change", "grace-left", 0, 20, 1, 1));
            page.Append(IntSlider("Grace right", "focus-change", "grace-right", 0, 20, 1, 1));

            // Focus request
            page.Append(SubSectionTitle("Focus Request"));
            page.Append(Toggle("Auto grant focus", "focus-request", "auto_grant_focus"));
            page.Append(Toggle("Auto focus children", "focus-request", "auto_focus_children", true));
            page.Append(IntSlider("Focus stealing timeout", "focus-request", "focus_stealing_timeout", 0, 10000, 100, 1000));
            page.Append(Keybind("Focus last demand", "focus-request", "focus_last_demand", "<alt> <ctrl> KEY_A"));

            // Focus steal prevent
            page.Append(SubSectionTitle("Focus Steal Prevention"));
            page.Append(IntSlider("Timeout", "focus-steal-prevent", "timeout", 0, 10000, 100, 1000));
            page.Append(Entry("Cancel keys", "focus-steal-prevent", "cancel_keys", "KEY_ENTER"));
            page.Append(Entry("Deny focus views", "focus-steal-prevent", "deny_focus_views", "none"));

            // Follow focus
            page.Append(SubSectionTitle("Follow Focus"));
            page.Append(Toggle("Change view", "follow-focus", "change_view", true));
            page.Append(Toggle("Change output", "follow-focus", "change_output", true));
            page.Append(Toggle("Raise on top", "follow-focus", "raise_on_top", true));
            page.Append(IntSlider("Focus delay", "follow-focus", "focus_delay", 0, 500, 10, 50));
            page.Append(IntSlider("Threshold", "follow-focus", "threshold", 0, 100, 1, 10));

            return page;
        }
    }
}
