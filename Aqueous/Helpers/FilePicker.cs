using System;

namespace Aqueous.Helpers;

public static class FilePicker
{
    public static async void Open(Gtk.Window? parent, string title = "Select File",
        string? filterName = null, string[]? filterPatterns = null,
        Action<string?>? onResult = null)
    {
        var dialog = Gtk.FileDialog.New();
        dialog.SetTitle(title);

        if (filterPatterns is { Length: > 0 })
        {
            var filter = Gtk.FileFilter.New();
            filter.SetName(filterName ?? "Files");
            foreach (var p in filterPatterns) filter.AddPattern(p);
            var filters = Gio.ListStore.New(Gtk.FileFilter.GetGType());
            filters.Append(filter);
            dialog.SetFilters(filters);
        }

        try
        {
            var file = await dialog.OpenAsync(parent);
            onResult?.Invoke(file?.GetPath());
        }
        catch
        {
            onResult?.Invoke(null);
        }
    }

    public static void OpenImage(Gtk.Window? parent, Action<string?> onResult)
        => Open(parent, "Select Image", "Images",
            ["*.png", "*.jpg", "*.jpeg", "*.webp", "*.bmp", "*.svg"], onResult);
}
