using Gtk;
using static Aqueous.Features.Settings.SettingsWidgets;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class DevToolsPage
    {
        public static Gtk.Box Create(SettingsStore store)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            page.Append(SectionTitle("Developer Tools"));

            // Bench
            page.Append(SubSectionTitle("FPS Benchmark"));
            page.Append(Dropdown("Position", "bench", "position",
                ["top_left", "top_center", "top_right", "bottom_left", "bottom_center", "bottom_right"], "top_center"));
            page.Append(IntSlider("Average frames", "bench", "average_frames", 1, 100, 1, 25));

            // Show repaint
            page.Append(SubSectionTitle("Show Repaint"));
            page.Append(Keybind("Toggle", "showrepaint", "toggle", "<alt> <super> KEY_S"));
            page.Append(Toggle("Reduce flicker", "showrepaint", "reduce_flicker", true));

            // Show touch
            page.Append(SubSectionTitle("Show Touch"));
            page.Append(Keybind("Toggle", "showtouch", "toggle", "none"));
            page.Append(ColorPicker("Center color", "showtouch", "center_color", "#80008080"));
            page.Append(ColorPicker("Finger color", "showtouch", "finger_color", "#00800080"));
            page.Append(IntSlider("Touch radius", "showtouch", "touch_radius", 5, 100, 1, 25));
            page.Append(DurationSlider("Touch duration", "showtouch", "touch_duration", 0, 1000, 50, 250));

            // Crosshair
            page.Append(SubSectionTitle("Crosshair"));
            page.Append(ColorPicker("Line color", "crosshair", "line_color", "#FF0000FF"));
            page.Append(IntSlider("Line width", "crosshair", "line_width", 1, 10, 1, 2));

            // Annotate
            page.Append(SubSectionTitle("Screen Annotation"));
            page.Append(Keybind("Draw", "annotate", "draw", "<alt> <super> BTN_LEFT"));
            page.Append(Keybind("Clear workspace", "annotate", "clear_workspace", "<alt> <super> KEY_C"));
            page.Append(ColorPicker("Stroke color", "annotate", "stroke_color", "#FF0000FF"));
            page.Append(Slider("Line width", "annotate", "line_width", 0.5, 20, 0.5, 3));
            page.Append(Dropdown("Method", "annotate", "method",
                ["draw", "line", "rectangle", "circle"], "draw"));
            page.Append(Toggle("From center", "annotate", "from_center", true));

            // View shot
            page.Append(SubSectionTitle("Screenshot"));
            page.Append(Keybind("Capture", "view-shot", "capture", "<alt> <super> BTN_MIDDLE"));
            page.Append(Entry("Filename template", "view-shot", "filename", "/tmp/snapshot-%F-%T.png"));
            page.Append(Entry("Command", "view-shot", "command"));

            // Magnifier
            page.Append(SubSectionTitle("Magnifier"));
            page.Append(Keybind("Toggle", "mag", "toggle", "<alt> <super> KEY_M"));
            page.Append(IntSlider("Zoom level", "mag", "zoom_level", 10, 200, 5, 75));
            page.Append(IntSlider("Default height", "mag", "default_height", 100, 1000, 50, 500));

            return page;
        }
    }
}
