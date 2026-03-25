namespace Aqueous.Bindings.AstalWl
{
    public enum AstalWlOutputSubpixel
    {
        Unknown = 0,
        None = 1,
        HorizontalRgb = 2,
        HorizontalBgr = 3,
        VerticalRgb = 4,
        VerticalBgr = 5
    }

    public enum AstalWlOutputTransform
    {
        Normal = 0,
        Rotate90 = 1,
        Rotate180 = 2,
        Rotate270 = 3,
        Flipped = 4,
        Flipped90 = 5,
        Flipped180 = 6,
        Flipped270 = 7
    }

    [Flags]
    public enum AstalWlSeatCapabilities
    {
        Pointer = 1,
        Keyboard = 2,
        Touch = 4
    }
}
