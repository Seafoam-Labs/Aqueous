using System;
using System.Collections.Generic;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Per-output state mirrored from <c>river_output_v1</c> events plus the per-output tag/workspace
/// bookkeeping consumed by <see cref="Aqueous.Features.Tags.TagController"/>. Promoted out of the
/// nested-class declaration inside <see cref="RiverWindowManagerClient"/>.
/// </summary>
internal sealed class OutputEntry
{
    public IntPtr Proxy;
    public uint WlOutputName;

    /// <summary>
    /// The bound <c>wl_output</c> proxy this <c>river_output_v1</c> corresponds to, or
    /// <see cref="IntPtr.Zero"/> until it is bound and linked. This is the same proxy the
    /// compositor references in <c>ext_workspace_group_handle_v1.output_enter</c>, so it bridges a
    /// <see cref="Aqueous.Features.Workspaces.WorkspaceGroupInfo"/> (keyed by <c>wl_output</c>) to
    /// this output entry.
    /// </summary>
    public IntPtr WlOutput;

    public int X, Y, Width, Height;

    // Tags / Workspaces. 32-bit "currently visible tags" mask. Default is tag 1 (bit 0).
    // Mutated by TagController in response to Super+1.0 / Super+Ctrl+1.9 / Super+grave bindings.
    public uint VisibleTags = Aqueous.Features.Tags.TagState.DefaultTag;

    // Last-tagset stack for back-and-forth (Super+grave). Capped to keep the structure small; a deque
    // would be cleaner but Stack<T> is sufficient at this size.
    public uint LastVisibleTags = Aqueous.Features.Tags.TagState.DefaultTag;
    public readonly Stack<uint> TagHistory = new();
}
