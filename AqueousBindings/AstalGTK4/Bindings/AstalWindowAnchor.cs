namespace Aqueous.Bindings.AstalGTK4
{
    [NativeTypeName("unsigned int")]
    public enum AstalWindowAnchor : uint
    {
        ASTAL_WINDOW_ANCHOR_NONE = 1 << 0,
        ASTAL_WINDOW_ANCHOR_TOP = 1 << 1,
        ASTAL_WINDOW_ANCHOR_RIGHT = 1 << 2,
        ASTAL_WINDOW_ANCHOR_LEFT = 1 << 3,
        ASTAL_WINDOW_ANCHOR_BOTTOM = 1 << 4,
    }
}
