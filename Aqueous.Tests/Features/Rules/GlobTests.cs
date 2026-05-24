using Aqueous.Features.Rules;
using Xunit;

namespace Aqueous.Tests.Features.Rules;

/// <summary>
/// PR #2 — coverage for the anchored glob matcher used by <see cref="WindowRuleEngine"/>.
/// <see cref="Glob"/> is <c>internal</c>; this test project sees it via the
/// <c>InternalsVisibleTo</c> attribute on the production assembly. If that attribute is
/// absent, switch <see cref="Glob"/> to <c>public</c> — the matcher is small and safe to expose.
/// </summary>
public class GlobTests
{
    [Theory]
    [InlineData("dota2", "dota2", true)]
    [InlineData("dota2", "Dota2", false)]            // ordinal, case-sensitive
    [InlineData("dota2", "dota", false)]             // anchored on both ends
    [InlineData("steam_app_*", "steam_app_570", true)]
    [InlineData("steam_app_*", "steam_app_", true)]  // trailing '*' allows empty
    [InlineData("steam_app_*", "other", false)]
    [InlineData("*", "anything", true)]
    [InlineData("*", "", true)]
    [InlineData("a?c", "abc", true)]
    [InlineData("a?c", "ac", false)]                 // '?' is exactly one char
    [InlineData("*.exe", "game.exe", true)]
    [InlineData("*.exe", "game.exe.bak", false)]
    public void Matches_PatternsBehaveAsDocumented(string pattern, string value, bool expected)
    {
        Assert.Equal(expected, Glob.Matches(pattern, value));
    }

    [Fact]
    public void Matches_NullPattern_NeverMatches()
    {
        Assert.False(Glob.Matches(null, "anything"));
        Assert.False(Glob.Matches(null, null));
    }

    [Fact]
    public void Matches_NullValue_TreatedAsEmpty()
    {
        Assert.True(Glob.Matches("*", null));
        Assert.True(Glob.Matches("", null));
        Assert.False(Glob.Matches("x", null));
    }
}
