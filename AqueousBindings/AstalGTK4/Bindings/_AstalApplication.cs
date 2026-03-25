namespace Aqueous.Bindings.AstalGTK4
{
    public unsafe partial struct _AstalApplication
    {
        [NativeTypeName("GtkApplication")]
        public _GtkApplication parent_instance;

        [NativeTypeName("AstalApplicationPrivate *")]
        public _AstalApplicationPrivate* priv;
    }
}
