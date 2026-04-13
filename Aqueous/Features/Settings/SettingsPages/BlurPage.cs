using Gtk;
using static Aqueous.Features.Settings.SettingsWidgets;

namespace Aqueous.Features.Settings.SettingsPages
{
    public static class BlurPage
    {
        public static Gtk.Box Create(SettingsStore store)
        {
            var page = Gtk.Box.New(Orientation.Vertical, 8);
            page.AddCssClass("settings-page");

            page.Append(SectionTitle("Blur"));

            page.Append(Dropdown("Method", "blur", "method",
                ["kawase", "gaussian", "box", "bokeh"], "kawase"));
            page.Append(Slider("Saturation", "blur", "saturation", 0, 2, 0.05, 1));
            page.Append(Keybind("Toggle", "blur", "toggle", "none"));
            page.Append(Entry("Blur by default", "blur", "blur_by_default", "type is \"toplevel\""));

            page.Append(SubSectionTitle("Kawase"));
            page.Append(IntSlider("Degrade", "blur", "kawase_degrade", 1, 10, 1, 3));
            page.Append(IntSlider("Iterations", "blur", "kawase_iterations", 1, 20, 1, 2));
            page.Append(Slider("Offset", "blur", "kawase_offset", 0.1, 10, 0.1, 1.7));

            page.Append(SubSectionTitle("Gaussian"));
            page.Append(IntSlider("Degrade", "blur", "gaussian_degrade", 1, 10, 1, 1));
            page.Append(IntSlider("Iterations", "blur", "gaussian_iterations", 1, 20, 1, 2));
            page.Append(Slider("Offset", "blur", "gaussian_offset", 0.1, 10, 0.1, 1));

            page.Append(SubSectionTitle("Box"));
            page.Append(IntSlider("Degrade", "blur", "box_degrade", 1, 10, 1, 1));
            page.Append(IntSlider("Iterations", "blur", "box_iterations", 1, 20, 1, 2));
            page.Append(Slider("Offset", "blur", "box_offset", 0.1, 10, 0.1, 1));

            page.Append(SubSectionTitle("Bokeh"));
            page.Append(IntSlider("Degrade", "blur", "bokeh_degrade", 1, 10, 1, 1));
            page.Append(IntSlider("Iterations", "blur", "bokeh_iterations", 1, 30, 1, 15));
            page.Append(Slider("Offset", "blur", "bokeh_offset", 0.1, 20, 0.1, 5));

            return page;
        }
    }
}
