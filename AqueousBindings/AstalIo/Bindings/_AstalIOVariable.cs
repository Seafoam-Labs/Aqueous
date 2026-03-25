namespace Aqueous.Bindings.AstalIo
{
    public unsafe partial struct _AstalIOVariable
    {
        [NativeTypeName("AstalIOVariableBase")]
        public _AstalIOVariableBase parent_instance;
        public _AstalIOVariablePrivate* priv;
    }
}
