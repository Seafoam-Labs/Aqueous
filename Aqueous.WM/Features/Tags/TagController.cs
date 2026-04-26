using System;

namespace Aqueous.WM.Features.Tags;

/// <summary>
/// Mediates per-output <c>VisibleTags</c> and per-window <c>Tags</c>
/// mutations triggered by Super+digit / Super+grave keybindings, then
/// asks the host (the WM client) to recompute layout so the next
/// <c>render_start</c> reflects the new visible set.
///
/// <para>
/// Decoupled from <c>RiverWindowManagerClient</c> via the
/// <see cref="ITagHost"/> interface so the controller can be tested
/// without bringing up Wayland. The controller never talks to Wayland
/// directly: state mutations push their effects through the host
/// (which schedules a manage cycle, the manage cycle re-runs the
/// layout engine with the tag-filtered window set, and that emits
/// <c>hide</c> / <c>show</c> / <c>propose_dimensions</c> deltas).
/// </para>
/// </summary>
public sealed class TagController
{
    /// <summary>
    /// Host hook for retrieving and mutating tag-relevant state. The
    /// concrete implementation lives in
    /// <c>RiverWindowManagerClient</c>; tests can fake it.
    /// </summary>
    public interface ITagHost
    {
        /// <summary>Read the focused output's <c>VisibleTags</c>; null if no output is focused.</summary>
        uint? GetFocusedOutputVisibleTags();

        /// <summary>Set the focused output's <c>VisibleTags</c>; pushes the prior value onto its history.</summary>
        bool SetFocusedOutputVisibleTags(uint mask);

        /// <summary>Read the focused output's last-tagset (for back-and-forth); null if none/no output.</summary>
        uint? GetFocusedOutputLastTagset();

        /// <summary>Re-tag the focused window. Returns false if no focused window.</summary>
        bool SetFocusedWindowTags(uint mask);

        /// <summary>Toggle bits in the focused window's <c>Tags</c>. Returns false if no focused window.</summary>
        bool ToggleFocusedWindowTags(uint mask);

        /// <summary>Schedule a manage cycle so the new visibility/layout is flushed.</summary>
        void RequestRelayout();

        /// <summary>Self-heal focus if the previously-focused window just became invisible.</summary>
        void RepairFocusAfterTagChange();

        /// <summary>Optional sink invoked after every successful tag mutation (bar/IPC integration hook).</summary>
        Action<TagsChangedEvent>? TagsChanged { get; }
    }

    /// <summary>Origin of a tag-state change (used by <see cref="TagsChangedEvent"/>).</summary>
    public enum TagsChangeKind
    {
        ViewTags,
        ToggleViewTag,
        SendFocusedToTags,
        ToggleWindowTag,
        ViewAll,
        SwapLastTagset,
    }

    /// <summary>Event raised when tag state changes (consumed by IPC/bar in Phase B1g).</summary>
    public readonly record struct TagsChangedEvent(
        TagsChangeKind Kind,
        uint NewOutputVisibleTags,
        uint? NewWindowTags);

    private readonly ITagHost _host;

    public TagController(ITagHost host)
    {
        _host = host ?? throw new ArgumentNullException(nameof(host));
    }

    /// <summary>Set focused output's view to exactly <paramref name="mask"/>. Super+1..9.</summary>
    public bool ViewTags(uint mask)
    {
        if (mask == 0u) return false;
        if (!_host.SetFocusedOutputVisibleTags(mask)) return false;
        _host.RepairFocusAfterTagChange();
        _host.RequestRelayout();
        Raise(TagsChangeKind.ViewTags, mask, null);
        return true;
    }

    /// <summary>Set focused output's view to <see cref="TagState.AllTags"/>. Super+0.</summary>
    public bool ViewAll() => ViewTags(TagState.AllTags);

    /// <summary>Toggle a single tag's visibility on the focused output. Super+Ctrl+1..9.</summary>
    public bool ToggleViewTag(uint mask)
    {
        if (mask == 0u) return false;
        var cur = _host.GetFocusedOutputVisibleTags();
        if (cur is null) return false;
        uint next = cur.Value ^ mask;
        if (next == 0u) return false; // never leave an output with zero visible tags
        if (!_host.SetFocusedOutputVisibleTags(next)) return false;
        _host.RepairFocusAfterTagChange();
        _host.RequestRelayout();
        Raise(TagsChangeKind.ToggleViewTag, next, null);
        return true;
    }

    /// <summary>Re-tag the focused window to <paramref name="mask"/>. Super+Shift+1..9 / Super+Shift+0.</summary>
    public bool SendFocusedToTags(uint mask)
    {
        if (mask == 0u) return false;
        if (!_host.SetFocusedWindowTags(mask)) return false;
        _host.RepairFocusAfterTagChange();
        _host.RequestRelayout();
        Raise(TagsChangeKind.SendFocusedToTags, _host.GetFocusedOutputVisibleTags() ?? 0u, mask);
        return true;
    }

    /// <summary>Toggle a tag bit on the focused window's tag set. Super+Shift+Ctrl+1..9.</summary>
    public bool ToggleWindowTag(uint mask)
    {
        if (mask == 0u) return false;
        if (!_host.ToggleFocusedWindowTags(mask)) return false;
        _host.RepairFocusAfterTagChange();
        _host.RequestRelayout();
        Raise(TagsChangeKind.ToggleWindowTag, _host.GetFocusedOutputVisibleTags() ?? 0u, null);
        return true;
    }

    /// <summary>
    /// Swap focused output's <c>VisibleTags</c> with its previous value.
    /// Bound to Super+grave (and Super+Tab when not otherwise consumed).
    /// </summary>
    public bool SwapLastTagset()
    {
        var prev = _host.GetFocusedOutputLastTagset();
        if (prev is null || prev.Value == 0u) return false;
        if (!_host.SetFocusedOutputVisibleTags(prev.Value)) return false;
        _host.RepairFocusAfterTagChange();
        _host.RequestRelayout();
        Raise(TagsChangeKind.SwapLastTagset, prev.Value, null);
        return true;
    }

    private void Raise(TagsChangeKind kind, uint outputMask, uint? winMask)
    {
        var sink = _host.TagsChanged;
        sink?.Invoke(new TagsChangedEvent(kind, outputMask, winMask));
    }
}
