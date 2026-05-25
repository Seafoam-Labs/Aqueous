using System;
using System.Collections.Concurrent;
using System.IO;
using Aqueous.Features.Compositor.River;
using Aqueous.Features.Compositor.River.Registry;
using Aqueous.Features.Layout;
using Aqueous.Features.Rules;
using Xunit;

namespace Aqueous.Tests.Features.Rules;

/// <summary>
/// Pins the hot-reload contract of <see cref="RulesReloader"/>: re-read <c>rules.toml</c>,
/// swap the engine's rule list, walk every managed <see cref="WindowEntry"/> applying the
/// updated rule, and schedule a manage cycle iff something actually changed.
/// </summary>
public class RulesReloaderTests
{
    /// <summary>Minimal scoped env helper so tests don't leak state to each other.</summary>
    private sealed class ScopedEnv : IDisposable
    {
        private readonly string _key;
        private readonly string? _previous;
        public ScopedEnv(string key, string? value)
        {
            _key = key;
            _previous = Environment.GetEnvironmentVariable(key);
            Environment.SetEnvironmentVariable(key, value);
        }
        public void Dispose() => Environment.SetEnvironmentVariable(_key, _previous);
    }

    /// <summary>Counts <see cref="IManagerRequestSender.ScheduleManage"/> invocations.</summary>
    private sealed class FakeManagerRequestSender : IManagerRequestSender
    {
        public int ScheduleManageCalls { get; private set; }
        public void SendManagerRequest(uint opcode) { }
        public void ScheduleManage() => ScheduleManageCalls++;
        public bool InsideManageSequence { get; set; }
        public void Init(IntPtr managerProxy, IntPtr display) { }
        public bool IsBound => false;
        public void Reset() { }
    }

    // We use the real WindowRegistry (internal — accessible via InternalsVisibleTo) and
    // populate it by direct dictionary writes, bypassing the wayland-proxy ceremony of Track().
    // RulesReloader only ever iterates registry.Entries; that's all we need.

    /// <summary>Writes <paramref name="contents"/> to a temp file and points $AQUEOUS_RULES at it.</summary>
    private static (string path, ScopedEnv env, ScopedEnv xdg, ScopedEnv home) StageRulesFile(string contents)
    {
        var path = Path.Combine(Path.GetTempPath(), $"aqueous-rules-{Guid.NewGuid():N}.toml");
        File.WriteAllText(path, contents);
        var env = new ScopedEnv("AQUEOUS_RULES", path);
        // Suppress XDG / HOME so they can't accidentally satisfy ResolvePath instead.
        var xdg = new ScopedEnv("XDG_CONFIG_HOME", "/no/such/xdg");
        var home = new ScopedEnv("HOME", "/no/such/home");
        return (path, env, xdg, home);
    }

    /// <summary>Captures every Notify() call so we can assert reload feedback.</summary>
    private sealed class FakeNotificationPublisher : INotificationPublisher
    {
        public readonly System.Collections.Generic.List<(string summary, string? body, bool isError)> Calls = new();
        public void Notify(string summary, string? body = null, bool isError = false)
            => Calls.Add((summary, body, isError));
    }

    private static (RulesReloader reloader, WindowRuleEngine engine, WindowRegistry reg, FakeManagerRequestSender sender, FakeNotificationPublisher notifier)
        MakeReloader()
    {
        var engine = new WindowRuleEngine();
        var reg = new WindowRegistry();
        var sender = new FakeManagerRequestSender();
        var notifier = new FakeNotificationPublisher();
        var reloader = new RulesReloader(engine, reg, sender, notifier);
        return (reloader, engine, reg, sender, notifier);
    }

    private static WindowEntry RegisterEntry(WindowRegistry reg, IntPtr proxy, string? appId = null, string? title = null)
    {
        var w = new WindowEntry { Proxy = proxy, AppId = appId, Title = title };
        reg.Entries[proxy] = w;
        return w;
    }

    [Fact]
    public void Reload_RuleAdded_AttachesPlacementToExistingWindow()
    {
        var (reloader, _, reg, sender, notifier) = MakeReloader();
        var w = RegisterEntry(reg, new IntPtr(1), appId: "dota2");

        var (_, env, xdg, home) = StageRulesFile(
            "[[window]]\napp_id = \"dota2\"\nlayout = \"game-mode\"\nanchor = \"center\"\nsize = \"native\"\n");
        using (env) using (xdg) using (home)
        {
            var result = reloader.Reload();

            Assert.True(result.Succeeded);
            Assert.Equal(1, result.RuleCount);
            Assert.Equal(1, result.WindowsChanged);
            Assert.NotNull(w.Placement);
            Assert.True(w.Placement!.IsAnchor);
            Assert.Equal(1, sender.ScheduleManageCalls);

            // Success notification: non-error, summary mentions reload, body cites rule+window counts.
            var call = Assert.Single(notifier.Calls);
            Assert.False(call.isError);
            Assert.Contains("reloaded", call.summary, StringComparison.OrdinalIgnoreCase);
            Assert.Contains("1 rule", call.body ?? "");
            Assert.Contains("1 window", call.body ?? "");
        }
    }

    [Fact]
    public void Reload_NullNotifier_DoesNotThrow()
    {
        // Constructing with no notifier (the default param) must keep working so the
        // many tests / callsites that predate Option A stay green.
        var engine = new WindowRuleEngine();
        var reg = new WindowRegistry();
        var sender = new FakeManagerRequestSender();
        var reloader = new RulesReloader(engine, reg, sender);

        using var rulesEnv = new ScopedEnv("AQUEOUS_RULES", null);
        using var xdg = new ScopedEnv("XDG_CONFIG_HOME", "/no/such/xdg");
        using var home = new ScopedEnv("HOME", "/no/such/home");

        var result = reloader.Reload();
        Assert.True(result.Succeeded);
    }

    [Fact]
    public void Reload_RuleRemoved_ClearsPlacement()
    {
        var (reloader, engine, reg, sender, _) = MakeReloader();
        // Pre-seed: a window already has a Placement from a previous boot.
        engine.Reload(new[]
        {
            new WindowRule("dota2", null, null, "game-mode", AnchorKind.Center,
                SizeSpec.Native.Instance, 1.0, null, false),
        });
        var w = RegisterEntry(reg, new IntPtr(1), appId: "dota2");
        Aqueous.Features.Rules.RuleApplication.Apply(engine, w);
        Assert.NotNull(w.Placement);

        // New rules.toml has NO rule for dota2.
        var (_, env, xdg, home) = StageRulesFile("# empty file\n");
        using (env) using (xdg) using (home)
        {
            var result = reloader.Reload();

            Assert.True(result.Succeeded);
            Assert.Equal(0, result.RuleCount);
            Assert.Equal(1, result.WindowsChanged);
            Assert.Null(w.Placement);
            Assert.Equal(1, sender.ScheduleManageCalls);
        }
    }

    [Fact]
    public void Reload_NoSchemaChange_ReportsZeroChanged_AndDoesNotSchedule()
    {
        var (reloader, _, reg, sender, _) = MakeReloader();
        var w = RegisterEntry(reg, new IntPtr(1), appId: "dota2");

        var rulesToml = "[[window]]\napp_id = \"dota2\"\nlayout = \"game-mode\"\n";
        var (_, env, xdg, home) = StageRulesFile(rulesToml);
        using (env) using (xdg) using (home)
        {
            // First reload attaches placement.
            var r1 = reloader.Reload();
            Assert.Equal(1, r1.WindowsChanged);

            // Second reload with identical rules — placement is already correct, nothing to do.
            var r2 = reloader.Reload();
            Assert.True(r2.Succeeded);
            Assert.Equal(1, r2.RuleCount);
            Assert.Equal(0, r2.WindowsChanged);

            // ScheduleManage fired once (for the first reload) and not again for the no-op.
            Assert.Equal(1, sender.ScheduleManageCalls);
        }
    }

    [Fact]
    public void Reload_MissingFile_ClearsAllRules()
    {
        var (reloader, engine, reg, sender, _) = MakeReloader();
        // Pre-seed with a rule + matching window.
        engine.Reload(new[]
        {
            new WindowRule("dota2", null, null, "game-mode", AnchorKind.Center,
                SizeSpec.Native.Instance, 1.0, null, false),
        });
        var w = RegisterEntry(reg, new IntPtr(1), appId: "dota2");
        Aqueous.Features.Rules.RuleApplication.Apply(engine, w);
        Assert.NotNull(w.Placement);

        // No rules.toml on disk — drive every discovery path to a nonexistent location.
        using var rulesEnv = new ScopedEnv("AQUEOUS_RULES", null);
        using var xdg = new ScopedEnv("XDG_CONFIG_HOME", "/no/such/xdg");
        using var home = new ScopedEnv("HOME", "/no/such/home");

        var result = reloader.Reload();

        Assert.True(result.Succeeded);
        Assert.Equal(0, result.RuleCount);
        Assert.Null(result.LoadedPath);
        Assert.Equal(1, result.WindowsChanged);
        Assert.Null(w.Placement);
        Assert.Equal(1, sender.ScheduleManageCalls);
    }

    [Fact]
    public void Reload_NoManagedWindows_ReportsZeroChanged()
    {
        var (reloader, _, _, sender, _) = MakeReloader();
        var (_, env, xdg, home) = StageRulesFile(
            "[[window]]\napp_id = \"dota2\"\nlayout = \"game-mode\"\n");
        using (env) using (xdg) using (home)
        {
            var result = reloader.Reload();
            Assert.True(result.Succeeded);
            Assert.Equal(1, result.RuleCount);
            Assert.Equal(0, result.WindowsChanged);
            Assert.Equal(0, sender.ScheduleManageCalls);
        }
    }
}
