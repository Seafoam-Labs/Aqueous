namespace Aqueous.Bindings.AstalGTK4
{
    public unsafe partial struct _AstalApplicationClass
    {
        [NativeTypeName("GtkApplicationClass")]
        public _GtkApplicationClass parent_class;

        [NativeTypeName("void (*)(AstalApplication *, const gchar *, GSocketConnection *, GError **)")]
        public delegate* unmanaged[Cdecl]<_AstalApplication*, sbyte*, _GSocketConnection*, _GError**, void> request;
    }
}
