using System;
using Aqueous.Bindings.AstalGTK4;
using Gtk;

namespace Aqueous.Bindings.AstalGTK4.Services
{
    public unsafe class AstalSlider
    {
        private _AstalSlider* _handle;
        public Gtk.Widget GtkWidget { get; }

        public AstalSlider() : this(AstalGtk4Interop.astal_slider_new())
        {
        }

        internal AstalSlider(_AstalSlider* handle)
        {
            _handle = handle;
            GtkWidget = (Gtk.Widget)GObject.Internal.InstanceWrapper.WrapHandle<Gtk.Widget>((IntPtr)handle, false);
        }

        public double Value
        {
            get => AstalGtk4Interop.astal_slider_get_value(_handle);
            set => AstalGtk4Interop.astal_slider_set_value(_handle, value);
        }

        public double Min
        {
            get => AstalGtk4Interop.astal_slider_get_min(_handle);
            set => AstalGtk4Interop.astal_slider_set_min(_handle, value);
        }

        public double Max
        {
            get => AstalGtk4Interop.astal_slider_get_max(_handle);
            set => AstalGtk4Interop.astal_slider_set_max(_handle, value);
        }

        public double Step
        {
            get => AstalGtk4Interop.astal_slider_get_step(_handle);
            set => AstalGtk4Interop.astal_slider_set_step(_handle, value);
        }

        public double Page
        {
            get => AstalGtk4Interop.astal_slider_get_page(_handle);
            set => AstalGtk4Interop.astal_slider_set_page(_handle, value);
        }
    }
}
