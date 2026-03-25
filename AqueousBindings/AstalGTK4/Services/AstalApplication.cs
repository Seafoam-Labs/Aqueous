using System;
using Aqueous.Bindings.AstalGTK4;
using Gtk;

namespace Aqueous.Bindings.AstalGTK4.Services
{
    public unsafe class AstalApplication
    {
        private _AstalApplication* _handle;
        public Gtk.Application GtkApplication { get; }

        public AstalApplication() : this(AstalGtk4Interop.astal_application_new())
        {
        }

        internal AstalApplication(_AstalApplication* handle)
        {
            _handle = handle;
            GtkApplication = (Gtk.Application)GObject.Internal.InstanceWrapper.WrapHandle<Gtk.Application>((IntPtr)handle, false);
        }

        public string? GtkTheme
        {
            get => System.Runtime.InteropServices.Marshal.PtrToStringAnsi((IntPtr)AstalGtk4Interop.astal_application_get_gtk_theme(_handle));
            set => AstalGtk4Interop.astal_application_set_gtk_theme(_handle, (sbyte*)System.Runtime.InteropServices.Marshal.StringToHGlobalAnsi(value));
        }

        public void ApplyCss(string css, bool reset = false)
        {
            AstalGtk4Interop.astal_application_apply_css(_handle, (sbyte*)System.Runtime.InteropServices.Marshal.StringToHGlobalAnsi(css), reset ? 1 : 0);
        }

        public Gtk.Window? GetWindow(string name)
        {
            var ptr = AstalGtk4Interop.astal_application_get_window(_handle, (sbyte*)System.Runtime.InteropServices.Marshal.StringToHGlobalAnsi(name));
            return ptr == null ? null : (Gtk.Window)GObject.Internal.InstanceWrapper.WrapHandle<Gtk.Window>((IntPtr)ptr, false);
        }
    }
}
