using System;
using System.Runtime.InteropServices;
using Aqueous.Bindings.AstalGTK4;
using Gtk;

namespace Aqueous.Bindings.AstalGTK4.Services
{
    public unsafe class AstalWindow
    {
        private _AstalWindow* _handle;
        public Gtk.Window GtkWindow { get; }

        public AstalWindow() : this(AstalGtk4Interop.astal_window_new())
        {
        }

        internal AstalWindow(_AstalWindow* handle)
        {
            _handle = handle;
            GtkWindow = (Gtk.Window)GObject.Internal.InstanceWrapper.WrapHandle<Gtk.Window>((IntPtr)handle, false);
        }

        public string? Namespace
        {
            get => Marshal.PtrToStringAnsi((IntPtr)AstalGtk4Interop.astal_window_get_namespace(_handle));
            set => AstalGtk4Interop.astal_window_set_namespace(_handle, (sbyte*)Marshal.StringToHGlobalAnsi(value));
        }

        public AstalWindowAnchor Anchor
        {
            get => AstalGtk4Interop.astal_window_get_anchor(_handle);
            set => AstalGtk4Interop.astal_window_set_anchor(_handle, value);
        }

        public AstalExclusivity Exclusivity
        {
            get => AstalGtk4Interop.astal_window_get_exclusivity(_handle);
            set => AstalGtk4Interop.astal_window_set_exclusivity(_handle, value);
        }

        public AstalLayer Layer
        {
            get => AstalGtk4Interop.astal_window_get_layer(_handle);
            set => AstalGtk4Interop.astal_window_set_layer(_handle, value);
        }

        public AstalKeymode Keymode
        {
            get => AstalGtk4Interop.astal_window_get_keymode(_handle);
            set => AstalGtk4Interop.astal_window_set_keymode(_handle, value);
        }

        public int Monitor
        {
            get => AstalGtk4Interop.astal_window_get_monitor(_handle);
            set => AstalGtk4Interop.astal_window_set_monitor(_handle, value);
        }

        public int MarginTop
        {
            get => AstalGtk4Interop.astal_window_get_margin_top(_handle);
            set => AstalGtk4Interop.astal_window_set_margin_top(_handle, value);
        }

        public int MarginBottom
        {
            get => AstalGtk4Interop.astal_window_get_margin_bottom(_handle);
            set => AstalGtk4Interop.astal_window_set_margin_bottom(_handle, value);
        }

        public int MarginLeft
        {
            get => AstalGtk4Interop.astal_window_get_margin_left(_handle);
            set => AstalGtk4Interop.astal_window_set_margin_left(_handle, value);
        }

        public int MarginRight
        {
            get => AstalGtk4Interop.astal_window_get_margin_right(_handle);
            set => AstalGtk4Interop.astal_window_set_margin_right(_handle, value);
        }

        public void SetMargin(int margin)
        {
            AstalGtk4Interop.astal_window_set_margin(_handle, margin);
        }

        public void SetInputRegion(int x, int y, int width, int height)
        {
            var gdkSurface = GdkSurfaceInterop.gtk_native_get_surface((nint)_handle);
            if (gdkSurface == nint.Zero) return;

            var rect = new CairoRectangleInt { X = x, Y = y, Width = width, Height = height };
            var region = CairoRegionInterop.cairo_region_create_rectangle(ref rect);
            GdkSurfaceInterop.gdk_surface_set_input_region(gdkSurface, region);
            CairoRegionInterop.cairo_region_destroy(region);
        }

        public void ClearInputRegion()
        {
            var gdkSurface = GdkSurfaceInterop.gtk_native_get_surface((nint)_handle);
            if (gdkSurface == nint.Zero) return;

            GdkSurfaceInterop.gdk_surface_set_input_region(gdkSurface, nint.Zero);
        }
    }
}
