using System;
using Aqueous.Bindings.AstalGTK4;
using Gtk;

namespace Aqueous.Bindings.AstalGTK4.Services
{
    public unsafe class AstalBox
    {
        private _AstalBox* _handle;
        public Gtk.Box GtkBox { get; }

        public AstalBox() : this(AstalGtk4Interop.astal_box_new())
        {
        }

        internal AstalBox(_AstalBox* handle)
        {
            _handle = handle;
            GtkBox = (Gtk.Box)GObject.Internal.InstanceWrapper.WrapHandle<Gtk.Box>((IntPtr)handle, false);
        }

        public bool Vertical
        {
            get => AstalGtk4Interop.astal_box_get_vertical(_handle) != 0;
            set => AstalGtk4Interop.astal_box_set_vertical(_handle, value ? 1 : 0);
        }

        public Gtk.Widget? Child
        {
            get
            {
                var ptr = AstalGtk4Interop.astal_box_get_child(_handle);
                return ptr == null ? null : (Gtk.Widget)GObject.Internal.InstanceWrapper.WrapHandle<Gtk.Widget>((IntPtr)ptr, false);
            }
            set
            {
                IntPtr widgetPtr = value?.Handle?.DangerousGetHandle() ?? IntPtr.Zero;
                AstalGtk4Interop.astal_box_set_child(_handle, (_GtkWidget*)widgetPtr);
            }
        }
    }
}
