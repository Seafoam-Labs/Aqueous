namespace Aqueous.Bindings.AstalGTK4
{
    public unsafe partial struct _AstalSlider
    {
        [NativeTypeName("GtkScale")]
        public _GtkScale parent_instance;

        [NativeTypeName("AstalSliderPrivate *")]
        public _AstalSliderPrivate* priv;
    }
}
