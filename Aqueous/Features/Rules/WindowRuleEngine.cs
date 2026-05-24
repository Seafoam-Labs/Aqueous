using System.Collections.Generic;

namespace Aqueous.Features.Rules;

/// <summary>
/// Wayland-protocol-agnostic identity of a managed window, used as input to
/// <see cref="WindowRuleEngine.Resolve"/>. All three fields may be <see langword="null"/>
/// during the brief window between <c>manage_start</c> and the first <c>app_id</c> /
/// <c>title</c> event; rule resolution simply yields no match in that case.
/// </summary>
/// <param name="AppId">
/// <c>xdg_toplevel.app_id</c> as advertised by the client (Wayland-native) or by
/// <c>xwayland-satellite</c> on behalf of X11 clients.
/// </param>
/// <param name="XClass">
/// X11 <c>WM_CLASS</c> as reported via <c>xwayland-satellite</c>; <see langword="null"/>
/// for Wayland-native clients.
/// </param>
/// <param name="Title">
/// <c>xdg_toplevel.title</c>. May change over the lifetime of the window; the controller
/// re-resolves on title-change events.
/// </param>
public readonly record struct WindowIdentity(string? AppId, string? XClass, string? Title);

/// <summary>
/// Public surface of the rule engine. The engine is a pure function over a snapshot of the
/// rule list — no per-window state lives here; each call to <see cref="Resolve"/> rescans the
/// active list. Cost is fine in practice because rule lists are short (a handful of entries,
/// one per game / app) and resolution only happens on <c>manage_start</c> + identity-change
/// events, never per-frame.
/// </summary>
public interface IWindowRuleEngine
{
    /// <summary>
    /// First-match-wins resolution against the currently-loaded rule list. Returns
    /// <see langword="null"/> when no rule matches.
    /// </summary>
    WindowRule? Resolve(WindowIdentity identity);

    /// <summary>
    /// Replace the active rule list. Called once at boot and again on every
    /// <c>Super+R</c> reload. The engine takes a defensive copy so callers may mutate their
    /// own list afterwards without affecting subsequent <see cref="Resolve"/> calls.
    /// </summary>
    void Reload(IReadOnlyList<WindowRule> rules);
}

/// <summary>
/// Default <see cref="IWindowRuleEngine"/> implementation. Pure, single-threaded by design
/// (called only from the compositor dispatch loop); does no logging on its own so it stays
/// trivially testable.
/// <para>
/// Matching semantics:
/// </para>
/// <list type="bullet">
/// <item>A rule with multiple matchers requires <em>all</em> present matchers to match.</item>
/// <item>An absent matcher (<see langword="null"/> on the rule) is a wildcard for that field.</item>
/// <item>Patterns support <c>*</c> / <c>?</c> globs via <see cref="Glob.Matches"/>.</item>
/// <item>Rules are evaluated in declaration order; first hit wins.</item>
/// </list>
/// </summary>
public sealed class WindowRuleEngine : IWindowRuleEngine
{
    private IReadOnlyList<WindowRule> _rules;

    public WindowRuleEngine()
        : this(System.Array.Empty<WindowRule>())
    {
    }

    public WindowRuleEngine(IReadOnlyList<WindowRule> rules)
    {
        _rules = CopyOf(rules);
    }

    /// <inheritdoc />
    public WindowRule? Resolve(WindowIdentity identity)
    {
        var rules = _rules;
        for (int i = 0; i < rules.Count; i++)
        {
            var r = rules[i];
            if (Matches(r, identity))
            {
                return r;
            }
        }

        return null;
    }

    /// <inheritdoc />
    public void Reload(IReadOnlyList<WindowRule> rules) => _rules = CopyOf(rules);

    /// <summary>
    /// Read-only view of the currently-loaded rule list, primarily for diagnostics / tests.
    /// </summary>
    public IReadOnlyList<WindowRule> Rules => _rules;

    private static bool Matches(WindowRule rule, WindowIdentity id)
    {
        // A rule with no matchers would match every window; the parser already drops those,
        // but defend in depth here in case a caller constructs WindowRule directly.
        if (rule.AppId is null && rule.Class is null && rule.Title is null)
        {
            return false;
        }

        if (rule.AppId is not null && !Glob.Matches(rule.AppId, id.AppId))
        {
            return false;
        }

        if (rule.Class is not null && !Glob.Matches(rule.Class, id.XClass))
        {
            return false;
        }

        if (rule.Title is not null && !Glob.Matches(rule.Title, id.Title))
        {
            return false;
        }

        return true;
    }

    private static IReadOnlyList<WindowRule> CopyOf(IReadOnlyList<WindowRule> rules)
    {
        if (rules.Count == 0)
        {
            return System.Array.Empty<WindowRule>();
        }

        var copy = new WindowRule[rules.Count];
        for (int i = 0; i < rules.Count; i++)
        {
            copy[i] = rules[i];
        }

        return copy;
    }
}
