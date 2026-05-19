using System;

namespace Aqueous.Features.Compositor.River.Tags;

/// <summary>
/// Transient collaborator bridge for <see cref="Aqueous.Features.Tags.TagService"/>.
///
/// <para>
/// Each member is a temporary hook back into <see cref="RiverWindowManagerClient"/>
/// to be retired by a later decomposition stage. The XML-doc on each member
/// names the stage that deletes it. When the last member is gone, this
/// interface itself goes away.
/// </para>
///
/// <para>
/// Single-implementation by design: only <see cref="RiverWindowManagerClient"/>
/// implements it explicitly. Tests fake this interface directly.
/// </para>
/// </summary>
internal interface ITagServiceCollaborators
{
    /// <summary>
    /// Currently keyboard-focused window, or <see cref="IntPtr.Zero"/>
    /// if none. -> retired in Stage 4 (becomes <c>IFocusService.FocusedWindow</c>).
    /// </summary>
    IntPtr FocusedWindow { get; }

    /// <summary>
    /// Clear the keyboard focus. -> retired in Stage 4 (becomes
    /// <c>IFocusService.ClearFocus</c>).
    /// </summary>
    void ClearFocus();

    /// <summary>
    /// Request keyboard focus on the given window proxy.
    /// -> retired in Stage 4 (becomes <c>IFocusService.RequestFocus</c>).
    /// </summary>
    void RequestFocus(IntPtr windowProxy);

    /// <summary>
    /// Schedule a manage cycle so the layout engine re-runs with the
    /// updated tag-filtered window set. -> retired in Stage 5 (becomes
    /// <c>ILayoutProposer.RequestRender</c> or equivalent).
    /// </summary>
    void ScheduleManage();
}
