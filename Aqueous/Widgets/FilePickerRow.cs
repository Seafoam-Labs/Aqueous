using System;

namespace Aqueous.Widgets;

public static class FilePickerRow
{
    public static Gtk.Box Create(string label, string currentValue = "",
        string? filterName = null, string[]? filterPatterns = null,
        Action<string>? onChanged = null)
    {
        var row = Gtk.Box.New(Gtk.Orientation.Horizontal, 8);
        row.AddCssClass("settings-row");

        var lbl = Gtk.Label.New(label);
        lbl.Hexpand = true;
        lbl.Halign = Gtk.Align.Start;
        row.Append(lbl);

        var entry = Gtk.Entry.New();
        var buffer = entry.GetBuffer();
        var safeValue = currentValue ?? "";
        buffer.SetText(safeValue, safeValue.Length);
        entry.WidthRequest = 200;
        entry.Hexpand = false;

        entry.OnChanged += (_, _) =>
        {
            onChanged?.Invoke(buffer.GetText());
        };
        row.Append(entry);

        var btn = Gtk.Button.NewWithLabel("Browse…");
        btn.OnClicked += (_, _) =>
        {
            var window = btn.GetRoot() as Gtk.Window;
            Helpers.FilePicker.Open(window, $"Select {label}", filterName, filterPatterns, path =>
            {
                if (path == null) return;
                buffer.SetText(path, path.Length);
                onChanged?.Invoke(path);
            });
        };
        row.Append(btn);

        return row;
    }
}
