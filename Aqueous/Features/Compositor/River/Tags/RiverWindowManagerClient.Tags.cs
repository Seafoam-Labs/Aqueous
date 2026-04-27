using System;
using Aqueous.Features.Tags;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Tag-host partial of <see cref="RiverWindowManagerClient"/>: implements
/// <see cref="TagController.ITagHost"/> by mutating the per-output and
/// per-window tag masks tracked in the outer client's dictionaries, and
/// exposes <c>GetFocusedOutputEntry</c> used by other partials.
/// Promoted out of the inline declaration during the Phase 2 Step 7
/// readability refactor.
/// </summary>
internal sealed unsafe partial class RiverWindowManagerClient
{
    // ---- TagController.ITagHost (Phase B1c) --------------------------

    /// <summary>
    /// Returns the OutputEntry the keyboard focus currently lives on.
    /// Falls back to a pointer-hovered output, then to the first
    /// known output. <c>null</c> if no outputs are tracked yet
    /// (e.g. the headless fallback).
    /// </summary>
    private OutputEntry? GetFocusedOutputEntry()
    {
        // 1. Output of the focused window.
        if (_focusedWindow != IntPtr.Zero &&
            _windows.TryGetValue(_focusedWindow, out var fw) &&
            fw.Output != IntPtr.Zero &&
            _outputs.TryGetValue(fw.Output, out var oeFromFocus))
        {
            return oeFromFocus;
        }

        // 2. First output (deterministic enough for single-output;
        //    pointer-position output resolution can be added when
        //    SeatInteractionService exposes it).
        foreach (var kv in _outputs)
        {
            return kv.Value;
        }

        return null;
    }

    uint? TagController.ITagHost.GetFocusedOutputVisibleTags()
        => GetFocusedOutputEntry()?.VisibleTags;

    uint? TagController.ITagHost.GetFocusedOutputLastTagset()
        => GetFocusedOutputEntry()?.LastVisibleTags;

    bool TagController.ITagHost.SetFocusedOutputVisibleTags(uint mask)
    {
        var oe = GetFocusedOutputEntry();
        if (oe is null)
        {
            return false;
        }

        if (oe.VisibleTags == mask)
        {
            return false;
        }

        // Push prior value onto history (cap to 8) and remember it
        // separately as LastVisibleTags for fast back-and-forth.
        oe.LastVisibleTags = oe.VisibleTags;
        oe.TagHistory.Push(oe.VisibleTags);
        while (oe.TagHistory.Count > 8)
        {
            // Drop oldest by rebuilding (Stack<T> has no DequeueLast).
            var arr = oe.TagHistory.ToArray();
            oe.TagHistory.Clear();
            for (int i = arr.Length - 2; i >= 0; i--)
            {
                oe.TagHistory.Push(arr[i]);
            }

            break;
        }

        oe.VisibleTags = mask;
        Log($"tags: output 0x{oe.Proxy.ToString("x")} VisibleTags=0x{mask:x8} (was 0x{oe.LastVisibleTags:x8})");
        return true;
    }

    bool TagController.ITagHost.SetFocusedWindowTags(uint mask)
    {
        if (_focusedWindow == IntPtr.Zero)
        {
            return false;
        }

        if (!_windows.TryGetValue(_focusedWindow, out var fw))
        {
            return false;
        }

        if (fw.Tags == mask)
        {
            return false;
        }

        fw.Tags = mask;
        Log($"tags: window 0x{_focusedWindow.ToString("x")} Tags=0x{mask:x8}");
        return true;
    }

    bool TagController.ITagHost.ToggleFocusedWindowTags(uint mask)
    {
        if (_focusedWindow == IntPtr.Zero)
        {
            return false;
        }

        if (!_windows.TryGetValue(_focusedWindow, out var fw))
        {
            return false;
        }

        uint next = fw.Tags ^ mask;
        if (next == 0u)
        {
            return false; // never end up untagged
        }

        fw.Tags = next;
        Log($"tags: window 0x{_focusedWindow.ToString("x")} Tags=0x{next:x8} (toggled 0x{mask:x8})");
        return true;
    }

    void TagController.ITagHost.RequestRelayout() => ScheduleManage();

    /// <summary>
    /// Self-heal focus when the previously-focused window has just
    /// become invisible because of a tag change. Picks the first
    /// window on the focused output that intersects the new
    /// VisibleTags; clears focus if none.
    /// </summary>
    void TagController.ITagHost.RepairFocusAfterTagChange()
    {
        if (_focusedWindow != IntPtr.Zero &&
            _windows.TryGetValue(_focusedWindow, out var fw))
        {
            uint mask = TagState.AllTags;
            if (fw.Output != IntPtr.Zero && _outputs.TryGetValue(fw.Output, out var oe))
            {
                mask = oe.VisibleTags;
            }

            if (TagState.IsVisible(fw.Tags, mask))
            {
                return; // still visible; keep focus.
            }
        }

        // Replacement: first visible window on the focused output,
        // else any visible window, else clear focus.
        IntPtr replacement = IntPtr.Zero;
        var focusedOe = GetFocusedOutputEntry();
        uint focusedMask = focusedOe?.VisibleTags ?? TagState.AllTags;
        IntPtr focusedOutput = focusedOe?.Proxy ?? IntPtr.Zero;

        foreach (var kv in _windows)
        {
            var w = kv.Value;
            if (focusedOutput != IntPtr.Zero && w.Output != focusedOutput)
            {
                continue;
            }

            if (!TagState.IsVisible(w.Tags, focusedMask))
            {
                continue;
            }

            replacement = kv.Key;
            break;
        }

        if (replacement == IntPtr.Zero)
        {
            ClearFocus();
        }
        else
        {
            RequestFocus(replacement);
        }
    }

    /// <summary>
    /// Optional sink consumed by the IPC bridge in Phase B1g.
    /// Settable from <c>Program.cs</c>; null by default so the
    /// hot path costs nothing.
    /// </summary>
    public Action<TagController.TagsChangedEvent>? TagsChanged { get; set; }

    Action<TagController.TagsChangedEvent>? TagController.ITagHost.TagsChanged => TagsChanged;
}
