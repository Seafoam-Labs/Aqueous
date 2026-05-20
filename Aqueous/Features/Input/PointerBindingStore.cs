using System;
using System.Collections.Generic;
using Aqueous.Features.SnapZones;

namespace Aqueous.Features.Input;

/// <summary>
/// DI singleton replacing the per-seat pointer binding state.
/// <para>
/// Pump-thread only.
/// </para>
/// </summary>
internal sealed class PointerBindingStore
{
    public IntPtr DragPointerBinding { get; set; }
    public bool DragPointerBindingNeedsEnable { get; set; }
    public IntPtr DragResizePointerBinding { get; set; }
    public bool DragResizePointerBindingNeedsEnable { get; set; }
    public Dictionary<IntPtr, SnapActivator> SnapActivatorBindings { get; } = new();
    public Dictionary<IntPtr, bool> SnapActivatorBindingNeedsEnable { get; } = new();
    public HashSet<IntPtr> SeatsWithPointerBindings { get; } = new();
}
