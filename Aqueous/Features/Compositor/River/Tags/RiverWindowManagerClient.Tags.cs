using System;
using Aqueous.Features.Compositor.River.Tags;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Residual tag-related partial of <see cref="RiverWindowManagerClient"/>
/// after the Stage 3 extraction (<see cref="Aqueous.Features.Tags.TagService"/>).
///
/// <para>
/// The previous <c>ITagHost</c> implementation moved into
/// <see cref="Aqueous.Features.Tags.TagService"/>. What stays here:
/// </para>
/// <list type="bullet">
/// <item><see cref="GetFocusedOutputEntry"/> — still called from
///       <c>RiverWindowStateHost</c> (out of scope for Stage 3; will move
///       when Stage 4 introduces <c>IFocusService</c>).</item>
/// <item>Explicit <see cref="ITagServiceCollaborators"/> implementation —
///       the transient bridge that <c>TagService</c> uses to drive focus
///       and relayout. Members are retired one-by-one in Stages 4–5.</item>
/// </list>
/// </summary>
internal sealed unsafe partial class RiverWindowManagerClient : ITagServiceCollaborators
{
    /// <summary>
    /// Returns the OutputEntry the keyboard focus currently lives on.
    /// Falls back to the first known output. <c>null</c> if no outputs
    /// are tracked yet (e.g. the headless fallback).
    /// </summary>
    private OutputEntry? GetFocusedOutputEntry()
    {
        if (_focusedWindow != IntPtr.Zero &&
            _windowRegistry.Entries.TryGetValue(_focusedWindow, out var fw) &&
            fw.Output != IntPtr.Zero &&
            _outputRegistry.Entries.TryGetValue(fw.Output, out var oeFromFocus))
        {
            return oeFromFocus;
        }

        foreach (var kv in _outputRegistry.Entries)
        {
            return kv.Value;
        }

        return null;
    }

    // ---- ITagServiceCollaborators (transient bridge, Stage 3) --------

    IntPtr ITagServiceCollaborators.FocusedWindow => _focusedWindow;

    void ITagServiceCollaborators.ClearFocus() => ClearFocus();

    void ITagServiceCollaborators.RequestFocus(IntPtr windowProxy) => RequestFocus(windowProxy);

    void ITagServiceCollaborators.ScheduleManage() => ScheduleManage();
}
