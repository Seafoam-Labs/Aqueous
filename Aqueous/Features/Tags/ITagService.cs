using System;

namespace Aqueous.Features.Tags;

/// <summary>
/// High-level tag operations exposed to keybindings / IPC / tests.
///
/// <para>
/// Wraps a <see cref="TagController"/> backed by a <see cref="TagController.ITagHost"/>
/// implementation that mutates per-output <c>VisibleTags</c> and per-window
/// <c>Tags</c> on the registries. This is the Stage 3 seam of the
/// <c>RiverWindowManagerClient</c> decomposition: callers should depend on
/// <see cref="ITagService"/>, not on the concrete <see cref="TagController"/>
/// or on the WM god class.
/// </para>
///
/// <para>
/// All methods are <b>pump-thread only</b>: they read/write registry entries
/// and trigger a relayout. Behaviour is identical to driving
/// <see cref="TagController"/> directly; <see cref="ITagService"/> exists so
/// future stages can swap the implementation (e.g. once an
/// <c>IFocusService</c> and <c>ILayoutProposer</c> land in Stages 4-5).
/// </para>
/// </summary>
public interface ITagService
{
    /// <summary>Set focused output's view to exactly <paramref name="mask"/>. Bound to Super+1..9. Returns false if no output is focused or the mask is unchanged/zero.</summary>
    bool ViewTags(uint mask);

    /// <summary>Set focused output's view to <see cref="TagState.AllTags"/>. Bound to Super+0.</summary>
    bool ViewAll();

    /// <summary>Toggle a tag's visibility on the focused output. Bound to Super+Ctrl+1..9.</summary>
    bool ToggleViewTag(uint mask);

    /// <summary>Re-tag the focused window to <paramref name="mask"/>. Bound to Super+Shift+1..9 / Super+Shift+0.</summary>
    bool SendFocusedToTags(uint mask);

    /// <summary>Toggle a tag bit on the focused window's tag set. Bound to Super+Shift+Ctrl+1..9.</summary>
    bool ToggleWindowTag(uint mask);

    /// <summary>Swap focused output's <c>VisibleTags</c> with its previous value. Bound to Super+grave.</summary>
    bool SwapLastTagset();

    /// <summary>
    /// Optional sink invoked after every successful tag mutation
    /// (IPC / bar integration hook).
    /// </summary>
    Action<TagController.TagsChangedEvent>? TagsChanged { get; set; }
}
