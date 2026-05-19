using System;

namespace Aqueous.Features.Compositor.River.Tags;

/// <summary>
/// Transient collaborator bridge for <see cref="Aqueous.Features.Tags.TagService"/>.
///
/// <para>
/// As of Stage 4 only one member remains: the manage-cycle hook
/// (<see cref="ScheduleManage"/>). The three focus-related members
/// (<c>FocusedWindow</c>, <c>ClearFocus</c>, <c>RequestFocus</c>) were
/// retired and replaced by <see cref="Aqueous.Features.Focus.IFocusService"/>
/// injected directly into <c>TagService</c>.
/// </para>
///
/// <para>
/// The remaining member retires in Stage 5 once
/// <c>ILayoutProposer.RequestRender</c> takes over manage-cycle
/// scheduling. At that point this interface and its single-implementing
/// partial on <see cref="RiverWindowManagerClient"/> disappear.
/// </para>
/// </summary>
internal interface ITagServiceCollaborators
{
    /// <summary>
    /// Schedule a manage cycle so the layout engine re-runs with the
    /// updated tag-filtered window set. -> retired in Stage 5 (becomes
    /// <c>ILayoutProposer.RequestRender</c> or equivalent).
    /// </summary>
    void ScheduleManage();
}
