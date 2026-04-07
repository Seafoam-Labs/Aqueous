using System.Runtime.InteropServices;

namespace Aqueous.Bindings.AstalGTK4;

public static partial class GdkSurfaceInterop
{
    [LibraryImport("libgtk-4.so.1")]
    public static partial nint gtk_native_get_surface(nint native);

    [LibraryImport("libgtk-4.so.1")]
    public static partial void gdk_surface_set_input_region(nint surface, nint region);
}

public static partial class CairoRegionInterop
{
    [LibraryImport("libcairo.so.2")]
    public static partial nint cairo_region_create();

    [LibraryImport("libcairo.so.2")]
    public static partial nint cairo_region_create_rectangle(ref CairoRectangleInt rect);

    [LibraryImport("libcairo.so.2")]
    public static partial void cairo_region_destroy(nint region);
}

[StructLayout(LayoutKind.Sequential)]
public struct CairoRectangleInt
{
    public int X, Y, Width, Height;
}
