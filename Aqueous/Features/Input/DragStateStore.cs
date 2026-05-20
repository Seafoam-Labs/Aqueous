using System;
using System.Collections.Concurrent;
using System.Threading;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.SnapZones;

namespace Aqueous.Features.Input;

/// The god class keeps property aliases pointing at this store until every remaining consumer
/// (manager/window services, drag-pointer-binding service, seat handler) takes the store via ctor
/// injection directly.
/// </para>
/// </summary>
internal sealed class DragStateStore
{
    private WindowEntry? _activeDragWindow;
    private SnapActivator _activeDragActivator = SnapActivator.Always;

    public WindowEntry? ActiveDragWindow
    {
        get => Volatile.Read(ref _activeDragWindow);
        set => Volatile.Write(ref _activeDragWindow, value);
    }

    public SnapActivator ActiveDragActivator
    {
        get => _activeDragActivator;
        set => _activeDragActivator = value;
    }

    public ConcurrentDictionary<IntPtr, (int X, int Y)> SeatPointerPos { get; } = new();

    // Drag-rect / lifecycle state. Pump-thread only.
    public IntPtr ActiveDragSeat { get; set; }
    public bool DragStarted { get; set; }
    public bool DragFinished { get; set; }
    public uint DragEdges { get; set; }
    public int DragStartX { get; set; }
    public int DragStartY { get; set; }
    public int DragStartW { get; set; }
    public int DragStartH { get; set; }
    public int DragStartPointerX { get; set; }
    public int DragStartPointerY { get; set; }
    public bool DragResizeInformed { get; set; }

    // Seat -> hovered window proxy. Concurrent because pointer-enter/leave events can race with the
    // manage cycle reading this map.
    public ConcurrentDictionary<IntPtr, IntPtr> SeatHoveredWindow { get; } = new();
}
