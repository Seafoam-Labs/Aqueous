using System;
using System.Collections.Generic;

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
    public HashSet<IntPtr> SeatsWithPointerBindings { get; } = new();
}
