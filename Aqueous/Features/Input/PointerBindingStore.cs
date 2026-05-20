using System;
using System.Collections.Generic;
using Aqueous.Features.SnapZones;

namespace Aqueous.Features.Input;

/// <summary>
/// PR 9.12 §2.13 Step 5 — DI singleton replacing the per-seat pointer
/// binding state previously owned as private fields on
/// <see cref="Aqueous.Features.Compositor.River.RiverWindowManagerClient"/>:
/// the move/resize binding proxies, their post-bind "needs enable"
/// flags, the snap-activator binding proxies and their enable flags,
/// and the per-seat dedupe set for <c>get_pointer_binding</c>.
///
/// <para>Pump-thread only.</para>
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
