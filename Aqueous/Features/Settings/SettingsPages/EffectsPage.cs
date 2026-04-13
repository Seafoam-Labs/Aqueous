using Gtk;
using static Aqueous.Features.Settings.SettingsWidgets;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class EffectsPage
    {
        public static Gtk.Box Create(SettingsStore store)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            page.Append(SectionTitle("Visual Effects"));

            // Wobbly
            page.Append(SubSectionTitle("Wobbly Windows"));
            page.Append(Slider("Friction", "wobbly", "friction", 0.1, 10, 0.1, 3));
            page.Append(Slider("Spring constant", "wobbly", "spring_k", 0.1, 20, 0.1, 8));
            page.Append(IntSlider("Grid resolution", "wobbly", "grid_resolution", 1, 20, 1, 6));

            // Alpha / Transparency
            page.Append(SubSectionTitle("Transparency"));
            page.Append(Slider("Min alpha", "alpha", "min_value", 0, 1, 0.05, 0.1));
            page.Append(Keybind("Modifier", "alpha", "modifier", "<alt> <super>"));

            // Invert
            page.Append(SubSectionTitle("Color Inversion"));
            page.Append(Keybind("Toggle", "invert", "toggle", "<super> KEY_I"));
            page.Append(Toggle("Preserve hue", "invert", "preserve_hue"));

            // Water
            page.Append(SubSectionTitle("Water Effect"));
            page.Append(Keybind("Activate", "water", "activate", "<ctrl> <super> BTN_LEFT"));

            // Window Rotation
            page.Append(SubSectionTitle("Window Rotation"));
            page.Append(Keybind("Activate", "wrot", "activate", "<ctrl> <super> BTN_RIGHT"));
            page.Append(Keybind("Activate 3D", "wrot", "activate-3d", "<shift> <super> BTN_RIGHT"));
            page.Append(IntSlider("Sensitivity", "wrot", "sensitivity", 1, 100, 1, 24));
            page.Append(Keybind("Reset all", "wrot", "reset", "<ctrl> <super> KEY_R"));
            page.Append(Keybind("Reset one", "wrot", "reset-one", "<super> KEY_R"));
            page.Append(Toggle("Invert", "wrot", "invert"));

            // Fisheye
            page.Append(SubSectionTitle("Fisheye"));
            page.Append(Keybind("Toggle", "fisheye", "toggle", "<ctrl> <super> KEY_F"));
            page.Append(Slider("Radius", "fisheye", "radius", 10, 1000, 10, 450));
            page.Append(Slider("Zoom", "fisheye", "zoom", 1, 20, 0.5, 7));

            // Screen Zoom
            page.Append(SubSectionTitle("Screen Zoom"));
            page.Append(Keybind("Modifier", "zoom", "modifier", "<super>"));
            page.Append(Slider("Speed", "zoom", "speed", 0.001, 0.1, 0.001, 0.01));
            page.Append(DurationSlider("Smoothing duration", "zoom", "smoothing_duration", 0, 1000, 50, 300));
            page.Append(Dropdown("Interpolation", "zoom", "interpolation_method",
                ["0", "1"], "0"));

            // Per-Window Zoom
            page.Append(SubSectionTitle("Per-Window Zoom"));
            page.Append(Slider("Zoom step", "winzoom", "zoom_step", 0.01, 1, 0.01, 0.1));
            page.Append(Keybind("Modifier", "winzoom", "modifier", "<ctrl> <super>"));
            page.Append(Keybind("Increase X", "winzoom", "inc_x_binding", "<ctrl> <super> KEY_RIGHT"));
            page.Append(Keybind("Decrease X", "winzoom", "dec_x_binding", "<ctrl> <super> KEY_LEFT"));
            page.Append(Keybind("Increase Y", "winzoom", "inc_y_binding", "<ctrl> <super> KEY_DOWN"));
            page.Append(Keybind("Decrease Y", "winzoom", "dec_y_binding", "<ctrl> <super> KEY_UP"));
            page.Append(Toggle("Preserve aspect", "winzoom", "preserve_aspect", true));
            page.Append(Toggle("Nearest filtering", "winzoom", "nearest_filtering"));

            // Keycolor
            page.Append(SubSectionTitle("Chroma Key"));
            page.Append(ColorPicker("Color", "keycolor", "color", "#000000FF"));
            page.Append(Slider("Opacity", "keycolor", "opacity", 0, 1, 0.05, 0.25));
            page.Append(Slider("Threshold", "keycolor", "threshold", 0, 1, 0.05, 0.5));

            return page;
        }
    }
}
