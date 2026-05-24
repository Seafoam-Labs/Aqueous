using System;
using Aqueous.Diagnostics;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Layout;

namespace Aqueous.Features.Rules;

/// <summary>
/// Outcome of a single <see cref="IRulesReloader.Reload"/> call. Returned for logs and tests;
/// the WM proper has no behavioural dependency on the result beyond the implicit
/// <c>ScheduleManage()</c> that fires when anything actually changed.
/// </summary>
public sealed record RulesReloadResult(
    int RuleCount,
    int WindowsChanged,
    string? LoadedPath,
    bool Succeeded);

/// <summary>
/// Hot-reload entry point for <c>rules.toml</c>. Re-reads the file via the documented
/// discovery order (<c>$AQUEOUS_RULES</c> → <c>[rules].path</c> → XDG → <c>~</c>), atomically
/// swaps the rule list on the singleton <see cref="IWindowRuleEngine"/>, then walks every
/// managed <c>WindowEntry</c> re-resolving its identity. Outputs are dirtied indirectly via
/// <see cref="IManagerRequestSender.ScheduleManage"/> when any placement changes.
/// </summary>
public interface IRulesReloader
{
    /// <summary>
    /// Re-load <c>rules.toml</c> and re-evaluate every managed window. Never throws —
    /// parse failures keep the previous engine state and return <c>Succeeded == false</c>.
    /// </summary>
    RulesReloadResult Reload();
}

/// <inheritdoc />
internal sealed class RulesReloader : IRulesReloader
{
    private readonly IWindowRuleEngine _engine;
    private readonly IWindowRegistry _registry;
    private readonly IManagerRequestSender _managerRequestSender;

    public RulesReloader(
        IWindowRuleEngine engine,
        IWindowRegistry registry,
        IManagerRequestSender managerRequestSender)
    {
        _engine = engine ?? throw new ArgumentNullException(nameof(engine));
        _registry = registry ?? throw new ArgumentNullException(nameof(registry));
        _managerRequestSender = managerRequestSender ?? throw new ArgumentNullException(nameof(managerRequestSender));
    }

    public RulesReloadResult Reload()
    {
        // The reader is permissive — it never throws and falls back to RulesConfig.Empty on
        // any error. We still wrap defensively so that an unexpected exception (DI, env
        // resolution, etc.) cannot bring down a Super+R keypress.
        RulesConfig cfg;
        string? path;
        try
        {
            path = RulesTomlReader.ResolvePath(null);
            cfg  = RulesTomlReader.Load();
        }
        catch (Exception ex)
        {
            RiverLog.Write("reload_rules: failed to load rules.toml: " + ex.Message);
            return new RulesReloadResult(RuleCount: 0, WindowsChanged: 0, LoadedPath: null, Succeeded: false);
        }

        // Atomic swap; subsequent Resolve() calls see the new list.
        _engine.Reload(cfg.Windows);

        // Re-resolve every managed window. We mirror WindowEventService.ApplyRule's contract
        // exactly so behaviour stays identical to the cold-start path.
        int changed = 0;
        foreach (var kvp in _registry.Entries)
        {
            var w = kvp.Value;
            if (RuleApplication.Apply(_engine, w))
            {
                changed++;
            }
        }

        if (changed > 0)
        {
            // Any placement change can shift the per-output anchor set; let the layout
            // proposer pick up the new state on the next frame.
            _managerRequestSender.ScheduleManage();
        }

        RiverLog.Write($"reload_rules: rules={cfg.Windows.Count} changed={changed} path={path ?? "<none>"}");
        return new RulesReloadResult(
            RuleCount: cfg.Windows.Count,
            WindowsChanged: changed,
            LoadedPath: path,
            Succeeded: true);
    }
}

/// <summary>
/// Single-source-of-truth helper for "resolve a window's identity against the engine and
/// update its <see cref="WindowEntry.Placement"/>". Both the on-event path
/// (<c>WindowEventService.ApplyRule</c>) and the bulk-reload path (<see cref="RulesReloader"/>)
/// delegate here so the two cannot drift.
/// </summary>
internal static class RuleApplication
{
    /// <summary>
    /// Re-resolves <paramref name="w"/>'s identity against <paramref name="engine"/> and
    /// updates <see cref="WindowEntry.Placement"/> iff the resolved rule actually changed.
    /// Returns <c>true</c> when the placement was mutated (the caller may want to dirty
    /// the owning output).
    /// </summary>
    public static bool Apply(IWindowRuleEngine engine, WindowEntry w)
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
}
