namespace Aqueous.Bindings.AstalWl
{
    public unsafe partial struct _AstalWlRegistry
    {
        [NativeTypeName("GObject")]
        public _GObject parent_instance;
        public _AstalWlRegistryPrivate* priv;
        public _GHashTable* globals;
        public _GHashTable* outputs;
        public _GHashTable* seats;
    }
}
