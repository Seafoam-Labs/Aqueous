using System;
using System.Runtime.InteropServices;

namespace Aqueous.Bindings.AstalGTK4;

public static unsafe partial class GdkInterop
{
    [LibraryImport("libgdk-4.so.1")]
    public static partial _GdkDisplay* gdk_display_get_default();

    [LibraryImport("libgdk-4.so.1")]
    public static partial _GListModel* gdk_display_get_monitors(_GdkDisplay* display);

    [LibraryImport("libgio-2.0.so.0")]
    public static partial void* g_list_model_get_item(_GListModel* list, uint position);

    [LibraryImport("libgio-2.0.so.0")]
    public static partial uint g_list_model_get_n_items(_GListModel* list);

    [LibraryImport("libgdk-4.so.1")]
    public static partial void gdk_monitor_get_geometry(_GdkMonitor* monitor, out GdkRectangle geometry);

    [StructLayout(LayoutKind.Sequential)]
    public struct GdkRectangle
    {
        public int X;
        public int Y;
        public int Width;
        public int Height;
    }
}
