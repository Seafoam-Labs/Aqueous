using System;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Layout;
using Aqueous.Features.Rules;
using Xunit;

namespace Aqueous.Tests.Features.Rules;

/// <summary>
/// PR #4 step 2 — pins the data-flow contract between the rule engine, the river-side
/// <see cref="WindowEntry"/>, and the layout-engine view <see cref="WindowEntryView"/>.
/// <para>
/// The wiring under test is what <c>WindowEventService.ApplyRule</c> does on every
/// app_id / title transition (resolve the identity → attach a <see cref="RulePlacement"/>
/// to the entry) plus what <c>LayoutProposer</c> does each frame (copy
/// <c>Placement</c> / buffer-size / focus-tick onto the engine view). These tests verify
/// that data shape end-to-end without needing the unsafe River dispatcher or DI host.
/// </para>
/// </summary>
public class WindowEntryRuleWiringTests
{
    private static WindowRule DotaRule(string layout = "game-mode") =>
        new(AppId: "dota2", Class: null, Title: null,
            Layout: layout,
            Anchor: AnchorKind.Center,
            Size: SizeSpec.Native.Instance,
            Scale: 1.0, Tag: null, Fullscreen: false);

    /// <summary>Mimics the body of <c>WindowEventService.ApplyRule</c>.</summary>
    private static bool ApplyRule(IWindowRuleEngine engine, WindowEntry w)
    {
        var resolved = engine.Resolve(new WindowIdentity(w.AppId, XClass: null, w.Title));
        var old = w.Placement;
        bool changed =
            (old is null) != (resolved is null) ||
            (old is not null && resolved is not null && !old.Rule.Equals(resolved));
        if (!changed) return false;
        w.Placement = resolved is null ? null : new RulePlacement(resolved);
        return true;
    }

    private static WindowEntryView ViewOf(WindowEntry w) =>
        new(Handle: w.Proxy,
            MinW: w.MinW, MinH: w.MinH, MaxW: w.MaxW, MaxH: w.MaxH,
            Floating: w.Floating, Fullscreen: false, Tags: w.Tags,
            Placement: w.Placement,
            RequestedBufferW: w.WidthHint,
            RequestedBufferH: w.HeightHint,
            LastFocusTick: w.LastFocusTick);

    [Fact]
    public void ApplyRule_MatchingAppId_AttachesPlacement_AndReportsChanged()
    {
        var engine = new WindowRuleEngine(new[] { DotaRule() });
        var w = new WindowEntry { Proxy = new IntPtr(1), AppId = "dota2" };

        bool changed = ApplyRule(engine, w);

        Assert.True(changed);
        Assert.NotNull(w.Placement);
        Assert.True(w.Placement!.IsAnchor);
        Assert.Equal("dota2", w.Placement.Rule.AppId);
    }

    [Fact]
    public void ApplyRule_NoMatch_LeavesPlacementNull_AndReportsUnchanged()
    {
        var engine = new WindowRuleEngine(new[] { DotaRule() });
        var w = new WindowEntry { Proxy = new IntPtr(1), AppId = "firefox" };

        bool changed = ApplyRule(engine, w);

        Assert.False(changed);
        Assert.Null(w.Placement);
    }

    [Fact]
    public void ApplyRule_RepeatedWithSameIdentity_IsIdempotent()
    {
        var engine = new WindowRuleEngine(new[] { DotaRule() });
        var w = new WindowEntry { Proxy = new IntPtr(1), AppId = "dota2" };

        Assert.True(ApplyRule(engine, w));
        // Second call: same identity, same resolved rule → should report no change.
        Assert.False(ApplyRule(engine, w));
        Assert.NotNull(w.Placement);
    }

    [Fact]
    public void ApplyRule_LateAppIdChange_FlipsPlacementOn()
    {
        var engine = new WindowRuleEngine(new[] { DotaRule() });
        // Manage_start: no app_id yet (common with Steam-launched games).
        var w = new WindowEntry { Proxy = new IntPtr(1), AppId = null };
        Assert.False(ApplyRule(engine, w));
        Assert.Null(w.Placement);

        // Then the toplevel surfaces its real app_id.
        w.AppId = "dota2";
        Assert.True(ApplyRule(engine, w));
        Assert.True(w.Placement!.IsAnchor);
    }

    [Fact]
    public void ApplyRule_AppIdChangedToNonMatching_ClearsPlacement()
    {
        var engine = new WindowRuleEngine(new[] { DotaRule() });
        var w = new WindowEntry { Proxy = new IntPtr(1), AppId = "dota2" };
        Assert.True(ApplyRule(engine, w));
        Assert.NotNull(w.Placement);

        // Some clients re-set their app_id after launch (e.g. game launcher → game).
        w.AppId = "something-else";
        Assert.True(ApplyRule(engine, w));
        Assert.Null(w.Placement);
    }

    [Fact]
    public void ApplyRule_FullscreenRule_StillAttachesButIsNotAnchor()
    {
        // A game-mode rule with fullscreen=true is intentionally NOT an anchor — those
        // route through the existing toggle_fullscreen path instead. PR #2 pinned this
        // via RulePlacement.IsAnchor; this test pins the wiring respects it.
        var engine = new WindowRuleEngine(new[]
        {
            new WindowRule(AppId: "dota2", Class: null, Title: null,
                Layout: "game-mode", Anchor: AnchorKind.Center,
                Size: SizeSpec.Native.Instance, Scale: 1.0, Tag: null,
                Fullscreen: true),
        });
        var w = new WindowEntry { Proxy = new IntPtr(1), AppId = "dota2" };
        ApplyRule(engine, w);

        Assert.NotNull(w.Placement);
        Assert.False(w.Placement!.IsAnchor, "fullscreen rules must not produce anchors");
    }

    [Fact]
    public void Proposer_ViewMirrorsEntry_PlacementAndBufferAndFocusTick()
    {
        var engine = new WindowRuleEngine(new[] { DotaRule() });
        var w = new WindowEntry
        {
            Proxy = new IntPtr(42),
            AppId = "dota2",
            WidthHint = 1920,
            HeightHint = 1080,
            LastFocusTick = 17,
        };
        ApplyRule(engine, w);

        var view = ViewOf(w);

        Assert.True(view.IsAnchor);
        Assert.Same(w.Placement, view.Placement);
        Assert.Equal(1920, view.RequestedBufferW);
        Assert.Equal(1080, view.RequestedBufferH);
        Assert.Equal(17L, view.LastFocusTick);
    }

    [Fact]
    public void Proposer_ViewMirrorsEntry_NoRule_NoAnchor()
    {
        var w = new WindowEntry
        {
            Proxy = new IntPtr(7),
            AppId = "firefox",
            WidthHint = 800,
            HeightHint = 600,
        };
        var view = ViewOf(w);

        Assert.False(view.IsAnchor);
        Assert.Null(view.Placement);
        Assert.Equal(800, view.RequestedBufferW);
        Assert.Equal(600, view.RequestedBufferH);
        Assert.Equal(0L, view.LastFocusTick);
    }
}
