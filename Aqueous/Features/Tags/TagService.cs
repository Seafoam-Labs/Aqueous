using System;
using Aqueous.Diagnostics;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Focus;
using Aqueous.Features.Layout;

namespace Aqueous.Features.Tags;

/// <summary>
/// Stage 3 extraction of <c>RiverWindowManagerClient.Tags.cs</c>.
///
/// <para>
/// Implements both <see cref="ITagService"/> (the public, high-level
/// surface used by keybindings / IPC / tests) and
/// <see cref="TagController.ITagHost"/> (the low-level mutation hook
/// driven by an internally-owned <see cref="TagController"/>). The
/// per-output and per-window tag state lives on the registry entries
/// (<see cref="OutputEntry.VisibleTags"/>, <see cref="WindowEntry.Tags"/>)
/// — Stage 1 made the registries authoritative, so this class owns no
/// duplicated dictionaries.
/// </para>
///
/// <para>
/// Pump-thread only: every public method either reads/writes registry
/// entries (which are <see cref="System.Collections.Concurrent.ConcurrentDictionary{TKey,TValue}"/>
/// but still semantically pump-thread-owned for Wayland-visible state)
/// or asks the collaborator to schedule a manage cycle.
/// </para>
/// </summary>
internal sealed class TagService : ITagService, TagController.ITagHost
{
    private readonly IWindowRegistry _windowRegistry;
    private readonly IOutputRegistry _outputRegistry;
    private readonly IFocusService _focusService;
    // Stage 5: ScheduleManage now goes through IManagerRequestSender;
    // ITagServiceCollaborators retired (deleted) entirely.
    private readonly IManagerRequestSender _managerRequestSender;
    private readonly TagController _controller;
    public TagService(
        IWindowRegistry windowRegistry,
        IOutputRegistry outputRegistry,
        IFocusService focusService,
        IManagerRequestSender managerRequestSender)
    {
        _windowRegistry       = windowRegistry       ?? throw new ArgumentNullException(nameof(windowRegistry));
        _outputRegistry       = outputRegistry       ?? throw new ArgumentNullException(nameof(outputRegistry));
        _focusService         = focusService         ?? throw new ArgumentNullException(nameof(focusService));
        _managerRequestSender = managerRequestSender ?? throw new ArgumentNullException(nameof(managerRequestSender));
        _controller           = new TagController(this);
    }

    // ---- ITagService (façade forwarding to TagController) ------------

    public bool ViewTags(uint mask) => _controller.ViewTags(mask);
    public bool ViewAll() => _controller.ViewAll();
    public bool ToggleViewTag(uint mask) => _controller.ToggleViewTag(mask);
    public bool SendFocusedToTags(uint mask) => _controller.SendFocusedToTags(mask);
    public bool ToggleWindowTag(uint mask) => _controller.ToggleWindowTag(mask);
    public bool SwapLastTagset() => _controller.SwapLastTagset();

    public Action<TagController.TagsChangedEvent>? TagsChanged { get; set; }

    // ---- TagController.ITagHost (extracted partial body) -------------

    /// <summary>
    /// Returns the OutputEntry the keyboard focus currently lives on.
    /// Falls back to the first known output. <c>null</c> if no outputs
    /// are tracked yet (e.g. the headless fallback).
    /// </summary>
    private OutputEntry? GetFocusedOutputEntry()
    {
        // 1. Output of the focused window.
        var focused = _focusService.FocusedWindow;
        if (focused != IntPtr.Zero &&
            _windowRegistry.Entries.TryGetValue(focused, out var fw) &&
            fw.Output != IntPtr.Zero &&
            _outputRegistry.Entries.TryGetValue(fw.Output, out var oeFromFocus))
        {
            return oeFromFocus;
        }

        // 2. First output (deterministic enough for single-output;
        //    pointer-position output resolution can be added when
        //    SeatInteractionService exposes it).
        foreach (var kv in _outputRegistry.Entries)
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
        RiverLog.Write(
            $"tags: output 0x{oe.Proxy.ToString("x")} VisibleTags=0x{mask:x8} (was 0x{oe.LastVisibleTags:x8})");
        return true;
    }

    bool TagController.ITagHost.SetFocusedWindowTags(uint mask)
    {
        var focused = _focusService.FocusedWindow;
        if (focused == IntPtr.Zero)
        {
            return false;
        }

        if (!_windowRegistry.Entries.TryGetValue(focused, out var fw))
        {
            return false;
        }

        if (fw.Tags == mask)
        {
            return false;
        }

        fw.Tags = mask;
        RiverLog.Write(
            $"tags: window 0x{focused.ToString("x")} Tags=0x{mask:x8}");
        return true;
    }

    bool TagController.ITagHost.ToggleFocusedWindowTags(uint mask)
    {
        var focused = _focusService.FocusedWindow;
        if (focused == IntPtr.Zero)
        {
            return false;
        }

        if (!_windowRegistry.Entries.TryGetValue(focused, out var fw))
        {
            return false;
        }

        uint next = fw.Tags ^ mask;
        if (next == 0u)
        {
            return false; // never end up untagged
        }

        fw.Tags = next;
        RiverLog.Write(
            $"tags: window 0x{focused.ToString("x")} Tags=0x{next:x8} (toggled 0x{mask:x8})");
        return true;
    }

    void TagController.ITagHost.RequestRelayout() => _managerRequestSender.ScheduleManage();

    /// <summary>
    /// Self-heal focus when the previously-focused window has just
    /// become invisible because of a tag change. Picks the first
    /// window on the focused output that intersects the new
    /// VisibleTags; clears focus if none.
    /// </summary>
    void TagController.ITagHost.RepairFocusAfterTagChange()
    {
        var focused = _focusService.FocusedWindow;
        if (focused != IntPtr.Zero &&
            _windowRegistry.Entries.TryGetValue(focused, out var fw))
        {
            uint mask = TagState.AllTags;
            if (fw.Output != IntPtr.Zero && _outputRegistry.Entries.TryGetValue(fw.Output, out var oe))
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

        foreach (var kv in _windowRegistry.Entries)
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
            _focusService.ClearFocus();
        }
        else
        {
            _focusService.RequestFocus(replacement);
        }
    }

    Action<TagController.TagsChangedEvent>? TagController.ITagHost.TagsChanged => TagsChanged;
}
