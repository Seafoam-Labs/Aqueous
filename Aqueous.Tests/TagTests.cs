using System;
using System.Collections.Generic;
using Aqueous.Features.Tags;
using Xunit;

namespace Aqueous.Tests;

public class TagTests
{
    /// <summary>
    /// In-memory <see cref="TagController.ITagHost"/> for unit tests.
    /// Models a single output and a single focused window so we can
    /// exercise the controller's mutation/event semantics without
    /// bringing up Wayland.
    /// </summary>
    private sealed class FakeHost : TagController.ITagHost
    {
        public uint OutputVisible = TagState.DefaultTag;
        public uint OutputLast    = TagState.DefaultTag;
        public uint? FocusedWindowTags = TagState.DefaultTag;
        public int RelayoutCalls;
        public int RepairCalls;
        public List<TagController.TagsChangedEvent> Events = new();

        public uint? GetFocusedOutputVisibleTags() => OutputVisible;
        public uint? GetFocusedOutputLastTagset() => OutputLast;

        public bool SetFocusedOutputVisibleTags(uint mask)
        {
            if (OutputVisible == mask) return false;
            OutputLast = OutputVisible;
            OutputVisible = mask;
            return true;
        }

        public bool SetFocusedWindowTags(uint mask)
        {
            if (FocusedWindowTags is null) return false;
            if (FocusedWindowTags == mask) return false;
            FocusedWindowTags = mask;
            return true;
        }

        public bool ToggleFocusedWindowTags(uint mask)
        {
            if (FocusedWindowTags is null) return false;
            uint next = FocusedWindowTags.Value ^ mask;
            if (next == 0u) return false;
            FocusedWindowTags = next;
            return true;
        }

        public void RequestRelayout() => RelayoutCalls++;
        public void RepairFocusAfterTagChange() => RepairCalls++;

        public Action<TagController.TagsChangedEvent>? TagsChanged =>
            ev => Events.Add(ev);
    }

    [Fact]
    public void TagState_Bit_ProducesSingleBitMask()
    {
        Assert.Equal(1u, TagState.Bit(0));
        Assert.Equal(0x80u, TagState.Bit(7));
        Assert.Equal(1u << 31, TagState.Bit(31));
    }

    [Fact]
    public void TagState_IsVisible_IsBitwiseAnd()
    {
        Assert.True(TagState.IsVisible(0b0011u, 0b0001u));
        Assert.False(TagState.IsVisible(0b0010u, 0b0001u));
    }

    [Fact]
    public void ViewTags_SwitchesOutputView_AndTriggersRelayoutAndRepair()
    {
        var host = new FakeHost();
        var tc = new TagController(host);

        Assert.True(tc.ViewTags(TagState.Bit(1))); // tag 2

        Assert.Equal(2u, host.OutputVisible);
        Assert.Equal(1u, host.OutputLast);
        Assert.Equal(1, host.RelayoutCalls);
        Assert.Equal(1, host.RepairCalls);
        Assert.Single(host.Events);
        Assert.Equal(TagController.TagsChangeKind.ViewTags, host.Events[0].Kind);
        Assert.Equal(2u, host.Events[0].NewOutputVisibleTags);
    }

    [Fact]
    public void ViewTags_NoOpIfMaskUnchanged()
    {
        var host = new FakeHost();
        var tc = new TagController(host);
        Assert.False(tc.ViewTags(TagState.DefaultTag)); // already viewing tag 1
        Assert.Equal(0, host.RelayoutCalls);
    }

    [Fact]
    public void ViewAll_SetsAllTagsMask()
    {
        var host = new FakeHost();
        var tc = new TagController(host);
        Assert.True(tc.ViewAll());
        Assert.Equal(TagState.AllTags, host.OutputVisible);
    }

    [Fact]
    public void SendFocusedToTags_RetagsFocusedWindow()
    {
        var host = new FakeHost();
        var tc = new TagController(host);

        Assert.True(tc.SendFocusedToTags(TagState.Bit(2)));

        Assert.Equal(4u, host.FocusedWindowTags);
        Assert.Equal(1, host.RelayoutCalls);
        Assert.Single(host.Events);
        Assert.Equal(TagController.TagsChangeKind.SendFocusedToTags, host.Events[0].Kind);
        Assert.Equal((uint?)4u, host.Events[0].NewWindowTags);
    }

    [Fact]
    public void SendFocusedToTags_FailsWhenNoFocusedWindow()
    {
        var host = new FakeHost { FocusedWindowTags = null };
        var tc = new TagController(host);
        Assert.False(tc.SendFocusedToTags(TagState.Bit(0)));
        Assert.Equal(0, host.RelayoutCalls);
    }

    [Fact]
    public void ToggleViewTag_AddsAndRemovesBit()
    {
        var host = new FakeHost(); // starts at 0b0001
        var tc = new TagController(host);

        Assert.True(tc.ToggleViewTag(TagState.Bit(1))); // add tag 2
        Assert.Equal(0b0011u, host.OutputVisible);

        Assert.True(tc.ToggleViewTag(TagState.Bit(1))); // remove tag 2
        Assert.Equal(0b0001u, host.OutputVisible);
    }

    [Fact]
    public void ToggleViewTag_RefusesToLeaveOutputWithZeroVisibleTags()
    {
        var host = new FakeHost(); // visible = 0b0001
        var tc = new TagController(host);
        // Toggling the only visible bit would zero the mask — must be rejected.
        Assert.False(tc.ToggleViewTag(TagState.Bit(0)));
        Assert.Equal(0b0001u, host.OutputVisible);
    }

    [Fact]
    public void ToggleWindowTag_RefusesToLeaveWindowUntagged()
    {
        var host = new FakeHost { FocusedWindowTags = TagState.DefaultTag };
        var tc = new TagController(host);
        Assert.False(tc.ToggleWindowTag(TagState.Bit(0)));
        Assert.Equal((uint?)1u, host.FocusedWindowTags);
    }

    [Fact]
    public void SwapLastTagset_RestoresPreviousMask()
    {
        var host = new FakeHost();
        var tc = new TagController(host);

        tc.ViewTags(TagState.Bit(1)); // 2, last=1
        Assert.Equal(2u, host.OutputVisible);

        Assert.True(tc.SwapLastTagset()); // -> 1, last=2
        Assert.Equal(1u, host.OutputVisible);
        Assert.Equal(2u, host.OutputLast);
    }
}
