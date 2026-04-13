using Gtk;
using static Aqueous.Features.Settings.SettingsWidgets;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class CorePage
    {
        public static Gtk.Box Create(SettingsStore store)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            page.Append(SectionTitle("Core & Commands"));

            // Core
            page.Append(SubSectionTitle("Core"));
            page.Append(Entry("Plugins", "core", "plugins"));
            page.Append(ColorPicker("Background color", "core", "background_color", "#1A1A1AFF"));
            page.Append(Keybind("Close top view", "core", "close_top_view", "<super> KEY_Q | <alt> KEY_F4"));
            page.Append(Keybind("Exit compositor", "core", "exit", "<alt> <ctrl> KEY_BACKSPACE"));
            page.Append(Toggle("XWayland", "core", "xwayland", true));
            page.Append(IntSlider("Max render time", "core", "max_render_time", -1, 100, 1, -1));
            page.Append(Entry("Focus buttons", "core", "focus_buttons", "BTN_LEFT | BTN_MIDDLE | BTN_RIGHT"));
            page.Append(Toggle("Focus button with modifiers", "core", "focus_button_with_modifiers"));
            page.Append(Toggle("Focus buttons passthrough", "core", "focus_buttons_passthrough", true));
            page.Append(IntSlider("Transaction timeout", "core", "transaction_timeout", 10, 1000, 10, 100));

            // Custom commands
            page.Append(SubSectionTitle("Custom Commands"));
            page.Append(Keybind("Launcher binding", "command", "binding_aqueous_launcher", "<alt> KEY_SPACE"));
            page.Append(Entry("Launcher command", "command", "command_aqueous_launcher", "aqueous-applauncher"));
            page.Append(Keybind("SnapTo binding", "command", "binding_aqueous_snapto", "<ctrl> <super> KEY_S"));
            page.Append(Entry("SnapTo command", "command", "command_aqueous_snapto", "aqueous-snapto toggle"));

            // Workarounds
            page.Append(SubSectionTitle("Workarounds"));
            page.Append(Toggle("All dialogs modal", "workarounds", "all_dialogs_modal", true));
            page.Append(Toggle("Auto reload config", "workarounds", "auto_reload_config", true));
            page.Append(Toggle("Force frame sync", "workarounds", "force_frame_sync", true));
            page.Append(Toggle("Dynamic repaint delay", "workarounds", "dynamic_repaint_delay"));
            page.Append(Toggle("Disable primary selection", "workarounds", "disable_primary_selection"));
            page.Append(Toggle("Discard command output", "workarounds", "discard_command_output", true));
            page.Append(Toggle("Enable input method v2", "workarounds", "enable_input_method_v2"));
            page.Append(Toggle("Enable opaque region optimizations", "workarounds", "enable_opaque_region_damage_optimizations"));
            page.Append(Toggle("Enable SO unloading", "workarounds", "enable_so_unloading"));
            page.Append(Toggle("Focus main surface instead of popup", "workarounds", "focus_main_surface_instead_of_popup"));
            page.Append(Toggle("Force preferred decoration mode", "workarounds", "force_preferred_decoration_mode"));
            page.Append(Toggle("Keep last toplevel activated", "workarounds", "keep_last_toplevel_activated", true));
            page.Append(Toggle("Remove output limits", "workarounds", "remove_output_limits"));
            page.Append(Toggle("Use external output configuration", "workarounds", "use_external_output_configuration"));
            page.Append(IntSlider("Max buffer size", "workarounds", "max_buffer_size", 1024, 32768, 1024, 16384));
            page.Append(IntSlider("Config reload delay", "workarounds", "config_reload_delay", 0, 1000, 10, 20));
            page.Append(Dropdown("App ID mode", "workarounds", "app_id_mode",
                ["stock", "full"], "stock"));

            // Preserve output
            page.Append(SubSectionTitle("Preserve Output"));
            page.Append(IntSlider("Last output focus timeout", "preserve-output", "last_output_focus_timeout", 0, 60000, 1000, 10000));

            // XDG Activation
            page.Append(SubSectionTitle("XDG Activation"));
            page.Append(IntSlider("Timeout", "xdg-activation", "timeout", 0, 120, 1, 30));
            page.Append(Toggle("Check surface", "xdg-activation", "check_surface"));
            page.Append(Toggle("Only last request", "xdg-activation", "only_last_request"));

            return page;
        }
    }
}
