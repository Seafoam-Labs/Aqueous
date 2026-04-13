using Gtk;
using static Aqueous.Features.Settings.SettingsWidgets;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class AnimationsPage
    {
        public static Gtk.Box Create(SettingsStore store)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            page.Append(SectionTitle("Animations"));

            page.Append(Dropdown("Open animation", "animate", "open_animation",
                ["zoom", "fade", "fire", "spin", "zap", "none"], "zoom"));
            page.Append(Dropdown("Close animation", "animate", "close_animation",
                ["zoom", "fade", "fire", "spin", "zap", "none"], "zoom"));
            page.Append(Dropdown("Minimize animation", "animate", "minimize_animation",
                ["squeezimize", "zoom", "fade", "spin", "none"], "squeezimize"));

            page.Append(SubSectionTitle("Durations"));
            page.Append(DurationSlider("Default duration", "animate", "duration", 0, 2000, 50, 400));
            page.Append(DurationCurve("Default curve", "animate", "duration", "circle"));
            page.Append(DurationSlider("Zoom duration", "animate", "zoom_duration", 0, 2000, 50, 500));
            page.Append(DurationSlider("Fade duration", "animate", "fade_duration", 0, 2000, 50, 400));
            page.Append(DurationSlider("Spin duration", "animate", "spin_duration", 0, 2000, 50, 250));
            page.Append(IntSlider("Spin rotations", "animate", "spin_rotations", 1, 10, 1, 1));
            page.Append(DurationSlider("Squeezimize duration", "animate", "squeezimize_duration", 0, 2000, 50, 150));
            page.Append(DurationSlider("Zap duration", "animate", "zap_duration", 0, 2000, 50, 250));
            page.Append(DurationSlider("Startup duration", "animate", "startup_duration", 0, 2000, 50, 600));

            page.Append(SubSectionTitle("Fire Effect"));
            page.Append(ColorPicker("Fire color", "animate", "fire_color", "#B22303FF"));
            page.Append(IntSlider("Fire particles", "animate", "fire_particles", 100, 5000, 100, 2000));
            page.Append(Slider("Fire particle size", "animate", "fire_particle_size", 1, 64, 1, 16));
            page.Append(DurationSlider("Fire duration", "animate", "fire_duration", 0, 2000, 50, 300));
            page.Append(Toggle("Random fire color", "animate", "random_fire_color"));

            page.Append(SubSectionTitle("Extra Animations"));
            page.Append(DurationSlider("Blinds duration", "extra-animations", "blinds_duration", 0, 3000, 50, 700));
            page.Append(IntSlider("Blinds strip height", "extra-animations", "blinds_strip_height", 5, 100, 5, 20));
            page.Append(DurationSlider("Helix duration", "extra-animations", "helix_duration", 0, 3000, 50, 700));
            page.Append(IntSlider("Helix rotations", "extra-animations", "helix_rotations", 1, 10, 1, 2));
            page.Append(IntSlider("Helix strip height", "extra-animations", "helix_strip_height", 5, 100, 5, 20));
            page.Append(DurationSlider("Melt duration", "extra-animations", "melt_duration", 0, 3000, 50, 1000));
            page.Append(IntSlider("Melt distortion", "extra-animations", "melt_distortion_factor", 1, 100, 1, 20));
            page.Append(DurationSlider("Shatter duration", "extra-animations", "shatter_duration", 0, 3000, 50, 1000));
            page.Append(DurationSlider("Vortex duration", "extra-animations", "vortex_duration", 0, 3000, 50, 1000));

            return page;
        }
    }
}
