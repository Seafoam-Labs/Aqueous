using Aqueous.Features.Rules;
using Xunit;

namespace Aqueous.Tests.Features.Rules;

/// <summary>
/// PR #2 — behaviour of <see cref="WindowRuleEngine"/>. Pins the contract the upcoming
/// layout-engine PR (#4) will rely on: first-match-wins, all-present-matchers-must-match,
/// glob support, defensive list copy on <see cref="WindowRuleEngine.Reload"/>.
/// </summary>
public class WindowRuleEngineTests
{
    private static WindowRule Rule(
        string? appId = null,
        string? @class = null,
        string? title = null,
        string layout = "game-mode",
        bool fullscreen = false) =>
        new(
            AppId: appId,
            Class: @class,
            Title: title,
            Layout: layout,
            Anchor: AnchorKind.Center,
            Size: SizeSpec.Native.Instance,
            Scale: 1.0,
            Tag: null,
            Fullscreen: fullscreen);

    [Fact]
    public void Resolve_NoRules_ReturnsNull()
    {
        var eng = new WindowRuleEngine();

        Assert.Null(eng.Resolve(new WindowIdentity("dota2", null, null)));
    }

    [Fact]
    public void Resolve_AppIdMatch_ReturnsRule()
    {
        var rule = Rule(appId: "dota2");
        var eng = new WindowRuleEngine(new[] { rule });

        var hit = eng.Resolve(new WindowIdentity("dota2", null, "Dota 2"));

        Assert.Equal(rule, hit);
    }

    [Fact]
    public void Resolve_AppIdMismatch_ReturnsNull()
    {
        var eng = new WindowRuleEngine(new[] { Rule(appId: "dota2") });

        Assert.Null(eng.Resolve(new WindowIdentity("firefox", null, null)));
    }

    [Fact]
    public void Resolve_GlobAppId_Matches()
    {
        var rule = Rule(appId: "steam_app_*");
        var eng = new WindowRuleEngine(new[] { rule });

        Assert.Equal(rule, eng.Resolve(new WindowIdentity("steam_app_570", null, null)));
        Assert.Null(eng.Resolve(new WindowIdentity("firefox", null, null)));
    }

    [Fact]
    public void Resolve_MultipleMatchers_AllMustMatch()
    {
        var rule = Rule(appId: "game", title: "Game*");
        var eng = new WindowRuleEngine(new[] { rule });

        // both match → hit
        Assert.Equal(rule, eng.Resolve(new WindowIdentity("game", null, "Game Window")));
        // app_id matches, title doesn't → miss
        Assert.Null(eng.Resolve(new WindowIdentity("game", null, "Other")));
        // title matches, app_id doesn't → miss
        Assert.Null(eng.Resolve(new WindowIdentity("other", null, "Game Window")));
    }

    [Fact]
    public void Resolve_FirstMatchWins_InDeclarationOrder()
    {
        var first = Rule(appId: "dota2", title: "first");
        var second = Rule(appId: "dota2", title: "second");
        var eng = new WindowRuleEngine(new[] { first, second });

        // Only the second rule's title would match — but first rule's title pattern doesn't,
        // so first is skipped and second wins.
        Assert.Equal(second, eng.Resolve(new WindowIdentity("dota2", null, "second")));

        // Both rules' patterns match a window with title "match-both"? No — patterns are
        // literal here. Make a window that matches both: change first to wildcard title.
        var firstWild = Rule(appId: "dota2", title: "*");
        var engWild = new WindowRuleEngine(new[] { firstWild, second });
        Assert.Equal(firstWild, engWild.Resolve(new WindowIdentity("dota2", null, "second")));
    }

    [Fact]
    public void Resolve_NullIdentityFieldsTreatedAsEmpty()
    {
        // A "*" pattern matches the empty string, so a wildcard rule still hits a window
        // whose app_id hasn't been advertised yet.
        var rule = Rule(appId: "*");
        var eng = new WindowRuleEngine(new[] { rule });

        Assert.Equal(rule, eng.Resolve(new WindowIdentity(null, null, null)));
    }

    [Fact]
    public void Resolve_MatcherlessRule_NeverMatches()
    {
        // Defense in depth: the parser drops matcher-less rules, but if a caller constructs
        // one directly, the engine must still refuse to match anything (a "match-all" rule
        // would be a footgun).
        var rule = Rule();
        var eng = new WindowRuleEngine(new[] { rule });

        Assert.Null(eng.Resolve(new WindowIdentity("anything", null, null)));
    }

    [Fact]
    public void Reload_ReplacesActiveRules()
    {
        var eng = new WindowRuleEngine(new[] { Rule(appId: "old") });
        Assert.NotNull(eng.Resolve(new WindowIdentity("old", null, null)));

        eng.Reload(new[] { Rule(appId: "new") });

        Assert.Null(eng.Resolve(new WindowIdentity("old", null, null)));
        Assert.NotNull(eng.Resolve(new WindowIdentity("new", null, null)));
    }

    [Fact]
    public void Reload_TakesDefensiveCopy()
    {
        // Mutating the caller's list after Reload must not affect the engine.
        var list = new System.Collections.Generic.List<WindowRule> { Rule(appId: "a") };
        var eng = new WindowRuleEngine();
        eng.Reload(list);

        list.Clear();
        list.Add(Rule(appId: "b"));

        Assert.NotNull(eng.Resolve(new WindowIdentity("a", null, null)));
        Assert.Null(eng.Resolve(new WindowIdentity("b", null, null)));
    }

    [Fact]
    public void Placement_IsAnchor_ReflectsRuleShape()
    {
        // Sanity-check that the RulePlacement → IsAnchor wiring matches the documented
        // contract: game-mode + non-fullscreen = anchor.
        Assert.True(new RulePlacement(Rule()).IsAnchor);
        Assert.False(new RulePlacement(Rule(fullscreen: true)).IsAnchor);
        Assert.False(new RulePlacement(Rule(layout: "tile")).IsAnchor);
    }
}
