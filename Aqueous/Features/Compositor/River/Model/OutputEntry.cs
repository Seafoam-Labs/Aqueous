using System;
namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Per-output state mirrored from <c>river_output_v1</c> events plus the per-output workspace
/// bookkeeping consumed by <c>ext-workspace-v1</c>. Promoted out of the nested-class declaration
/// inside <see cref="RiverWindowManagerClient"/>.
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
}
