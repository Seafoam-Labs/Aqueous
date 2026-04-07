using System;

namespace Aqueous.Features.SystemTray
{
    public static class IconResolver
    {
        public static Gtk.Image? Resolve(TrayItem item)
        {
            if (!string.IsNullOrEmpty(item.IconName))
            {
                var theme = Gtk.IconTheme.GetForDisplay(Gdk.Display.GetDefault()!);
                if (theme.HasIcon(item.IconName))
                {
                    var paintable = theme.LookupIcon(
                        item.IconName, null, 22,
                        1, Gtk.TextDirection.Ltr, (Gtk.IconLookupFlags)0);
                    if (paintable != null)
                        return Gtk.Image.NewFromPaintable(paintable);
                }
                // Try as a direct file path
                if (System.IO.File.Exists(item.IconName))
                    return Gtk.Image.NewFromFile(item.IconName);
            }

            if (item.IconPixmap is { Length: > 0 })
            {
                var best = item.IconPixmap[0];
                foreach (var px in item.IconPixmap)
                {
                    if (px.Width >= 22 && px.Width < best.Width)
                        best = px;
                }
                try
                {
                    // IconPixmap is ARGB32 in network byte order, convert to RGBA for GdkPixbuf
                    var data = (byte[])best.Data.Clone();
                    for (int i = 0; i < data.Length; i += 4)
                    {
                        byte a = data[i];
                        byte r = data[i + 1];
                        byte g = data[i + 2];
                        byte b = data[i + 3];
                        data[i] = r;
                        data[i + 1] = g;
                        data[i + 2] = b;
                        data[i + 3] = a;
                    }
                    var bytes = GLib.Bytes.New(data);
                    var texture = Gdk.MemoryTexture.New(best.Width, best.Height,
                        Gdk.MemoryFormat.R8g8b8a8, bytes, (nuint)(best.Width * 4));
                    return Gtk.Image.NewFromPaintable(texture);
                }
                catch { }
            }

            return Gtk.Image.NewFromIconName("application-x-executable");
        }
    }
}
