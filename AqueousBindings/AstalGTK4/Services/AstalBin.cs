using System;
using Aqueous.Bindings.AstalGTK4;
using Gtk;

namespace Aqueous.Bindings.AstalGTK4.Services
{
    public unsafe class AstalBin
    {
        private _AstalBin* _handle;
        public Gtk.Widget GtkWidget { get; }

        public AstalBin() : this(AstalGtk4Interop.astal_bin_new())
        {
        }

        internal AstalBin(_AstalBin* handle)
        {
            _handle = handle;
            GtkWidget = (Gtk.Widget)GObject.Internal.InstanceWrapper.WrapHandle<Gtk.Widget>((IntPtr)handle, false);
        }

        public Gtk.Widget? Child
        {
            get
            {
                var ptr = AstalGtk4Interop.astal_bin_get_child(_handle);
                return ptr == null ? null : (Gtk.Widget)GObject.Internal.InstanceWrapper.WrapHandle<Gtk.Widget>((IntPtr)ptr, false);
            }
            set
            {
                IntPtr widgetPtr = value?.Handle?.DangerousGetHandle() ?? IntPtr.Zero;
                AstalGtk4Interop.astal_bin_set_child(_handle, (_GtkWidget*)widgetPtr);
            }
        }
    }
}
