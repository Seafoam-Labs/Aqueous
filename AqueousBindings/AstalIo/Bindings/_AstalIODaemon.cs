namespace Aqueous.Bindings.AstalIo
{
    public unsafe partial struct _AstalIODaemon
    {
        [NativeTypeName("GApplication")]
        public _GApplication parent_instance;
        public _AstalIODaemonPrivate* priv;
    }
}
