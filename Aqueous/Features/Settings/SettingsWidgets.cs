using System;
using Gtk;

namespace Aqueous.Features.Settings
{
    public static class SettingsWidgets
    {
        private static WayfireConfigService Wf => WayfireConfigService.Instance;

        public static Gtk.Box Toggle(string label, string section, string key, bool defaultValue = false)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var lbl = Gtk.Label.New(label);
            lbl.Hexpand = true;
            lbl.Halign = Align.Start;
            row.Append(lbl);

            var toggle = Gtk.Switch.New();
            toggle.Active = Wf.GetBool(section, key, defaultValue);
            toggle.Valign = Align.Center;
            toggle.OnStateSet += (_, args) =>
            {
                Wf.SetBool(section, key, args.State);
                return false;
            };
            row.Append(toggle);

            return row;
        }

        public static Gtk.Box Slider(string label, string section, string key,
            double min, double max, double step, double defaultValue = 0, bool isInt = false)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var lbl = Gtk.Label.New(label);
            lbl.Halign = Align.Start;
            lbl.WidthRequest = 200;
            row.Append(lbl);

            var scale = Gtk.Scale.NewWithRange(Orientation.Horizontal, min, max, step);
            scale.Hexpand = true;
            scale.DrawValue = true;

            double current = isInt
                ? Wf.GetInt(section, key, (int)defaultValue)
                : Wf.GetFloat(section, key, (float)defaultValue);
            scale.SetValue(current);

            scale.OnChangeValue += (_, args) =>
            {
                if (isInt)
                    Wf.SetInt(section, key, (int)args.Value);
                else
                    Wf.SetFloat(section, key, (float)args.Value);
                return false;
            };
            row.Append(scale);

            return row;
        }

        public static Gtk.Box IntSlider(string label, string section, string key,
            int min, int max, int step = 1, int defaultValue = 0)
        {
            return Slider(label, section, key, min, max, step, defaultValue, isInt: true);
        }

        public static Gtk.Box Entry(string label, string section, string key, string defaultValue = "")
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var lbl = Gtk.Label.New(label);
            lbl.Hexpand = true;
            lbl.Halign = Align.Start;
            row.Append(lbl);

            var entry = Gtk.Entry.New();
            var buffer = entry.GetBuffer();
            buffer.SetText(Wf.GetString(section, key, defaultValue), -1);
            entry.WidthRequest = 200;

            entry.OnChanged += (_, _) =>
            {
                Wf.SetString(section, key, buffer.GetText());
            };
            row.Append(entry);

            return row;
        }

        public static Gtk.Box ColorPicker(string label, string section, string key, string defaultValue = "#000000FF")
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var lbl = Gtk.Label.New(label);
            lbl.Hexpand = true;
            lbl.Halign = Align.Start;
            row.Append(lbl);

            var colorBtn = Gtk.ColorDialogButton.New(Gtk.ColorDialog.New());
            var colorStr = Wf.GetColor(section, key, defaultValue);
            var rgba = new Gdk.RGBA();
            rgba.Parse(colorStr);
            colorBtn.SetRgba(rgba);

            colorBtn.OnNotify += (_, args) =>
            {
                if (args.Pspec.GetName() == "rgba")
                {
                    var c = colorBtn.GetRgba();
                    var hex = $"#{(int)(c.Red * 255):X2}{(int)(c.Green * 255):X2}{(int)(c.Blue * 255):X2}{(int)(c.Alpha * 255):X2}";
                    Wf.SetColor(section, key, hex);
                }
            };
            row.Append(colorBtn);

            return row;
        }

        public static Gtk.Box Dropdown(string label, string section, string key,
            string[] options, string defaultValue = "")
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var lbl = Gtk.Label.New(label);
            lbl.Hexpand = true;
            lbl.Halign = Align.Start;
            row.Append(lbl);

            var stringList = Gtk.StringList.New(options);
            var dropdown = Gtk.DropDown.New(stringList, null);

            var current = Wf.GetString(section, key, defaultValue);
            for (uint i = 0; i < options.Length; i++)
            {
                if (string.Equals(options[i], current, StringComparison.OrdinalIgnoreCase))
                {
                    dropdown.Selected = i;
                    break;
                }
            }

            dropdown.OnNotify += (_, args) =>
            {
                if (args.Pspec.GetName() == "selected" && dropdown.Selected < options.Length)
                {
                    Wf.SetString(section, key, options[dropdown.Selected]);
                }
            };
            row.Append(dropdown);

            return row;
        }

        public static Gtk.Box Keybind(string label, string section, string key, string defaultValue = "none")
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var lbl = Gtk.Label.New(label);
            lbl.Hexpand = true;
            lbl.Halign = Align.Start;
            row.Append(lbl);

            var entry = Gtk.Entry.New();
            var buffer = entry.GetBuffer();
            buffer.SetText(Wf.GetKeybind(section, key, defaultValue), -1);
            entry.WidthRequest = 200;
            entry.AddCssClass("keybind-entry");

            entry.OnChanged += (_, _) =>
            {
                Wf.SetKeybind(section, key, buffer.GetText());
            };
            row.Append(entry);

            return row;
        }

        public static Gtk.Box DurationSlider(string label, string section, string key,
            int min = 0, int max = 5000, int step = 50, int defaultMs = 300)
        {
            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var lbl = Gtk.Label.New(label);
            lbl.Halign = Align.Start;
            lbl.WidthRequest = 200;
            row.Append(lbl);

            var scale = Gtk.Scale.NewWithRange(Orientation.Horizontal, min, max, step);
            scale.Hexpand = true;
            scale.DrawValue = true;
            scale.SetValue(Wf.GetDurationMs(section, key, defaultMs));

            scale.OnChangeValue += (_, args) =>
            {
                Wf.SetDurationMs(section, key, (int)args.Value);
                return false;
            };
            row.Append(scale);

            return row;
        }

        public static Gtk.Box DurationCurve(string label, string section, string key, string defaultCurve = "linear")
        {
            string[] curves = ["linear", "circle", "sigmoid"];
            var currentCurve = Wf.GetDurationCurve(section, key, defaultCurve);

            var row = Gtk.Box.New(Orientation.Horizontal, 8);
            row.AddCssClass("settings-row");

            var lbl = Gtk.Label.New(label);
            lbl.Hexpand = true;
            lbl.Halign = Align.Start;
            row.Append(lbl);

            var stringList = Gtk.StringList.New(curves);
            var dropdown = Gtk.DropDown.New(stringList, null);

            for (uint i = 0; i < curves.Length; i++)
            {
                if (curves[i] == currentCurve)
                {
                    dropdown.Selected = i;
                    break;
                }
            }

            dropdown.OnNotify += (_, args) =>
            {
                if (args.Pspec.GetName() == "selected" && dropdown.Selected < curves.Length)
                {
                    var ms = Wf.GetDurationMs(section, key, 300);
                    Wf.SetDurationMs(section, key, ms, curves[dropdown.Selected]);
                }
            };
            row.Append(dropdown);

            return row;
        }

        public static Gtk.Box SectionTitle(string title)
        {
            var box = Gtk.Box.New(Orientation.Vertical, 0);
            box.MarginTop = 12;

            var lbl = Gtk.Label.New(title);
            lbl.AddCssClass("settings-section-title");
            lbl.Halign = Align.Start;
            box.Append(lbl);

            return box;
        }

        public static Gtk.Box FilePicker(string label, string section, string key,
            string defaultValue = "", string filterName = "All Files", string[]? filterPatterns = null)
        {
            return Aqueous.Widgets.FilePickerRow.Create(label,
                Wf.GetString(section, key, defaultValue),
                filterName, filterPatterns,
                path => Wf.SetString(section, key, path));
        }

        public static Gtk.Box SubSectionTitle(string title)
        {
            var box = Gtk.Box.New(Orientation.Vertical, 0);
            box.MarginTop = 8;

            var lbl = Gtk.Label.New(title);
            lbl.AddCssClass("settings-subsection-title");
            lbl.Halign = Align.Start;
            box.Append(lbl);

            return box;
        }
    }
}
