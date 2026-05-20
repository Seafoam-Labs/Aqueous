using System;
using System.Collections.Concurrent;
using System.Threading;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.SnapZones;

namespace Aqueous.Features.Input;

/// <summary>
/// PR 9.12 §2.13 Step 2 — singleton owning the three drag-related
/// fields that <see cref="Aqueous.Features.SnapZones.SnapZoneService"/>
/// (and several other services) previously read from
/// <c>RiverWindowManagerClient</c>:
/// <list type="bullet">
///   <item><description><c>ActiveDragWindow</c>: the <see cref="WindowEntry"/>
///   the user is currently dragging (move or resize), or <c>null</c>.</description></item>
///   <item><description><c>ActiveDragActivator</c>: the modifier baked into
///   the drag at press-time (controls which snap layout is active).</description></item>
///   <item><description><c>SeatPointerPos</c>: per-seat last-known compositor-space
///   pointer position cache, refreshed by <c>SeatEventHandler.PointerPosition</c>.</description></item>
/// </list>
///
/// <para>
/// The store is mutated only on the pump thread; the volatile/concurrent
/// primitives below preserve the previous field semantics on the god
/// class byte-for-byte. The god class keeps property aliases pointing
/// at this store until every remaining consumer (manager/window
/// services, drag-pointer-binding service, seat handler) takes the
/// store via ctor injection directly.
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

    // PR 9.12 §2.13 Step 5 — drag-rect / lifecycle state previously owned
    // as private fields on RiverWindowManagerClient. Pump-thread only.
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

    // seat -> hovered window proxy. Concurrent because pointer-enter/leave
    // events can race with the manage cycle reading this map.
    public ConcurrentDictionary<IntPtr, IntPtr> SeatHoveredWindow { get; } = new();
}
