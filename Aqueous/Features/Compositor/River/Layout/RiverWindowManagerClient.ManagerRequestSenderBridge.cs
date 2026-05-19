using System;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Stage 5 bridge: the original <c>SendManagerRequest</c> /
/// <c>ScheduleManage</c> helpers are now thin wrappers that forward to
/// <see cref="Aqueous.Features.Layout.IManagerRequestSender"/>. The
/// many existing call sites (partials, handlers) continue to call the
/// private methods unqualified, so they need no per-site edits.
///
/// <para>
/// Retired in Stage 9, when those call sites take
/// <c>IManagerRequestSender</c> as a constructor dependency directly.
/// </para>
/// </summary>
internal sealed unsafe partial class RiverWindowManagerClient
{
    /// <summary>
    /// Marshal a no-argument request on the bound
    /// <c>river_window_manager_v1</c> proxy at <paramref name="opcode"/> and
    /// immediately flush. Silently no-ops if the manager isn't bound yet.
    /// </summary>
    private void SendManagerRequest(uint opcode) =>
        _managerRequestSender.SendManagerRequest(opcode);

    /// <summary>
    /// Ask the compositor to start a new manage sequence so that any state
    /// changed outside of one (pending focus from pointer-enter, Super+Tab,
    /// close-and-refocus, drag start) actually gets flushed promptly.
    /// river_window_manager_v1::manage_dirty is opcode 3.
    /// </summary>
    private void ScheduleManage() =>
        _managerRequestSender.ScheduleManage();

    /// <summary>
    /// UTF-8 marshalling helper retained for the partials that haven't
    /// been extracted yet (e.g. tag-name display, key-binding-action
    /// custom strings). Pure native helper, no compositor state touched.
    /// </summary>
    private static string? MarshalUtf8(IntPtr p)
        => p == IntPtr.Zero ? null : System.Runtime.InteropServices.Marshal.PtrToStringUTF8(p);
}
