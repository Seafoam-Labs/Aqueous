namespace Aqueous.Features.Layout.Builtin;

public class DwindleLayout : ILayoutEngine
{
    public string Id { get; }
    public IReadOnlyList<WindowPlacement> Arrange(Rect usableArea, IReadOnlyList<WindowEntryView> visibleWindows, IntPtr focusedWindow, LayoutOptions opts, ref object? perOutputState) =>
        throw new NotImplementedException();
}
