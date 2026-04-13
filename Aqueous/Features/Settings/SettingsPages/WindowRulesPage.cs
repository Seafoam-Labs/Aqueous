using Gtk;
using static Aqueous.Features.Settings.SettingsWidgets;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class WindowRulesPage
    {
        public static Gtk.Box Create(SettingsStore store)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            page.Append(SectionTitle("Window Rules"));

            // Pin view
            page.Append(SubSectionTitle("Pin View"));
            page.Append(Keybind("Pin to all workspaces", "pin-view", "pin", "none"));

            // Ghost
            page.Append(SubSectionTitle("Ghost Windows"));
            page.Append(Entry("Ghost match", "ghost", "ghost_match"));
            page.Append(Keybind("Ghost toggle", "ghost", "ghost_toggle", "none"));

            // Force fullscreen
            page.Append(SubSectionTitle("Force Fullscreen"));
            page.Append(Keybind("Toggle", "force-fullscreen", "key_toggle_fullscreen", "<alt> <super> KEY_F"));
            page.Append(Toggle("Preserve aspect", "force-fullscreen", "preserve_aspect", true));
            page.Append(Toggle("Constrain pointer", "force-fullscreen", "constrain_pointer"));
            page.Append(Toggle("Transparent behind", "force-fullscreen", "transparent_behind_views", true));

            // Decoration forced/ignored views
            page.Append(SubSectionTitle("Decoration View Filters"));
            page.Append(Entry("Forced decoration views", "decoration", "forced_views", "none"));
            page.Append(Entry("Ignored decoration views", "decoration", "ignore_views", "none"));

            // Shortcuts inhibit
            page.Append(SubSectionTitle("Shortcuts Inhibit"));
            page.Append(Keybind("Break grab", "shortcuts-inhibit", "break_grab", "none"));
            page.Append(Entry("Ignore views", "shortcuts-inhibit", "ignore_views", "none"));
            page.Append(Entry("Inhibit by default", "shortcuts-inhibit", "inhibit_by_default", "none"));

            return page;
        }
    }
}
