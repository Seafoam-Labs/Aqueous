using System;
namespace Aqueous.Features.Compositor.River;
/// <summary>
/// Residual tag-related partial of <see cref="RiverWindowManagerClient"/>
/// after the Stage 3 + Stage 5 extractions
/// (<see cref="Aqueous.Features.Tags.TagService"/> +
/// <see cref="Aqueous.Features.Layout.IManagerRequestSender"/>).
///
/// <para>
/// As of Stage 5 the <c>ITagServiceCollaborators</c> bridge has been
/// deleted in full — its sole remaining member (<c>ScheduleManage</c>)
/// is now consumed via <c>IManagerRequestSender</c> directly. What
/// stays here is <see cref="GetFocusedOutputEntry"/> only, still
/// called from <c>RiverWindowStateHost</c>; this method retires when
/// Stage 2's lift is completed in Stage 5b / 8.
/// </para>
/// </summary>
internal sealed unsafe partial class RiverWindowManagerClient
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
}
