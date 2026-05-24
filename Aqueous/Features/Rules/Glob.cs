namespace Aqueous.Features.Rules;

/// <summary>
/// Tiny anchored glob matcher used by <see cref="WindowRuleEngine"/> to compare
/// <c>app_id</c> / <c>class</c> / <c>title</c> patterns from <c>rules.toml</c> against the
/// identity of a managed window. Supports only <c>*</c> (any run, possibly empty) and
/// <c>?</c> (exactly one character). No regex engine — keeps AOT trim warnings at zero.
/// <para>
/// Patterns are anchored on both ends (no implicit substring match). A literal pattern with
/// no wildcards is equivalent to ordinal string equality.
/// </para>
/// </summary>
public static class Glob
{
    /// <summary>
    /// Returns <see langword="true"/> when <paramref name="value"/> matches
    /// <paramref name="pattern"/>. A <see langword="null"/> pattern matches nothing; a
    /// <see langword="null"/> value matches only the empty / wildcard-only pattern (<c>"*"</c>).
    /// Matching is case-sensitive (ordinal), mirroring Wayland's <c>app_id</c> semantics.
    /// </summary>
    public static bool Matches(string? pattern, string? value)
    {
        if (pattern is null)
        {
            return false;
        }

        var v = value ?? string.Empty;

        // Fast path: no wildcards → ordinal equality.
        if (pattern.IndexOf('*') < 0 && pattern.IndexOf('?') < 0)
        {
            return string.Equals(pattern, v, System.StringComparison.Ordinal);
        }

        return MatchAt(pattern, 0, v, 0);
    }

    // Classic recursive-with-memo-free glob matcher. Patterns in this project are short
    // (app_id strings, window titles) so the worst-case backtracking cost is negligible.
    private static bool MatchAt(string p, int pi, string s, int si)
    {
        while (pi < p.Length)
        {
            char pc = p[pi];
            if (pc == '*')
            {
                // Collapse consecutive '*'s and try every possible suffix split.
                while (pi < p.Length && p[pi] == '*')
                {
                    pi++;
                }

                if (pi == p.Length)
                {
                    return true; // trailing '*' eats the rest
                }

                for (int k = si; k <= s.Length; k++)
                {
                    if (MatchAt(p, pi, s, k))
                    {
                        return true;
                    }
                }

                return false;
            }

            if (si >= s.Length)
            {
                return false;
            }

            if (pc != '?' && pc != s[si])
            {
                return false;
            }

            pi++;
            si++;
        }

        return si == s.Length;
    }
}
