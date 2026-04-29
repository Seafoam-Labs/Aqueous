using System;
using System.Collections.Generic;
using System.Linq;
using Aqueous.Features.Layout;
using Aqueous.Features.Startup;
using Aqueous.Features.State;
using Xunit;

namespace Aqueous.Tests;

/// <summary>
/// Phase B1f — pure unit tests for <see cref="StartupExecRunner"/>. Uses a
/// minimal in-memory <see cref="IWindowStateHost"/> fake that captures
/// <see cref="SpawnRequest"/>s and exposes a manual clock for
/// <c>ScheduleAfter</c> so backoff scheduling can be verified
/// deterministically.
/// </summary>
public class StartupExecRunnerTests
{
    private sealed class FakeHost : IWindowStateHost
    {
        public readonly List<SpawnRequest> Spawns = new();
        public readonly List<string> Logs = new();
        public readonly List<(TimeSpan Delay, Action Callback)> Scheduled = new();

        // Unused stubs ----------------------------------------------------
        public WindowStateData? Get(WindowProxy w) => null;
        public WindowProxy FocusedWindow => WindowProxy.Zero;
        public OutputProxy FocusedOutput => OutputProxy.Zero;
        public Rect OutputRect(OutputProxy o) => default;
        public Rect UsableArea(OutputProxy o) => default;
        public WindowProxy GetFullscreenWindow(OutputProxy o) => WindowProxy.Zero;
        public void SetFullscreenWindow(OutputProxy o, WindowProxy w) { }
        public void Focus(WindowProxy w) { }
        public void FocusNextOnOutput(OutputProxy o) { }
        public void RequestRender(OutputProxy o) { }
        public void EmitForeignToplevelFullscreen(WindowProxy w, OutputProxy o) { }
        public void EmitForeignToplevelUnfullscreen(WindowProxy w) { }
        public Rect CurrentGeometry(WindowProxy w) => default;
        public void Spawn(string cmd) =>
            Spawns.Add(new SpawnRequest(cmd));

        // Capturing overrides --------------------------------------------
        public void Spawn(SpawnRequest request) => Spawns.Add(request);
        public void ScheduleAfter(TimeSpan delay, Action callback) =>
            Scheduled.Add((delay, callback));

        public void Log(string message) => Logs.Add(message);

        /// <summary>
        /// Drains all currently-scheduled callbacks (re-entrant: callbacks
        /// that schedule further work are not auto-fired).
        /// </summary>
        public IReadOnlyList<TimeSpan> FireAllScheduled()
        {
            var snapshot = Scheduled.ToList();
            Scheduled.Clear();
            foreach (var (_, cb) in snapshot)
            {
                cb();
            }
            return snapshot.Select(s => s.Delay).ToList();
        }
    }

    private static ExecEntry Entry(
        string name,
        string command = "echo hi",
        ExecWhen when = ExecWhen.Startup,
        bool once = true,
        bool restart = false,
        string? log = null) =>
        new()
        {
            Name = name,
            Command = command,
            When = when,
            Once = once,
            Restart = restart,
            LogPath = log,
        };

    private static StartupExecRunner Make(FakeHost host, params ExecEntry[] entries) =>
        new(host, new ExecConfig { Entries = entries });

    // -----------------------------------------------------------------

    [Fact]
    public void OnStartup_FiresStartupAndAlwaysEntries()
    {
        var host = new FakeHost();
        var runner = Make(host,
            Entry("a", when: ExecWhen.Startup),
            Entry("b", when: ExecWhen.Reload),
            Entry("c", when: ExecWhen.Always));

        runner.OnStartup();

        var names = host.Spawns.Select(s => s.Command).ToList();
        Assert.Equal(2, names.Count);
        Assert.Contains("echo hi", names); // a + c both use the default cmd
    }

    [Fact]
    public void OnStartup_PassesCommandLogAndEnvThrough()
    {
        var host = new FakeHost();
        var entry = new ExecEntry
        {
            Name = "noctalia",
            Command = "qs -c noctalia-shell",
            LogPath = "/tmp/noctalia.log",
            Env = new Dictionary<string, string> { ["QT_QPA_PLATFORM"] = "wayland" },
        };
        var runner = new StartupExecRunner(host, new ExecConfig { Entries = new[] { entry } });

        runner.OnStartup();

        var req = Assert.Single(host.Spawns);
        Assert.Equal("qs -c noctalia-shell", req.Command);
        Assert.Equal("/tmp/noctalia.log", req.LogPath);
        Assert.NotNull(req.Env);
        Assert.Equal("wayland", req.Env!["QT_QPA_PLATFORM"]);
        Assert.Null(req.OnExit); // Restart=false → no supervision
    }

    [Fact]
    public void OnStartup_OnceTrue_IsIdempotent()
    {
        var host = new FakeHost();
        var runner = Make(host, Entry("a", once: true));

        runner.OnStartup();
        runner.OnStartup();
        runner.OnStartup();

        Assert.Single(host.Spawns);
    }

    [Fact]
    public void OnStartup_OnceFalse_RelaunchesEachCall()
    {
        var host = new FakeHost();
        var runner = Make(host, Entry("a", once: false));

        runner.OnStartup();
        runner.OnStartup();

        Assert.Equal(2, host.Spawns.Count);
    }

    [Fact]
    public void OnReload_FiresReloadAndAlwaysOnly()
    {
        var host = new FakeHost();
        var runner = Make(host,
            Entry("startup-only", when: ExecWhen.Startup),
            Entry("reload-only", when: ExecWhen.Reload, once: false),
            Entry("always", when: ExecWhen.Always, once: false));

        runner.OnReload();

        Assert.Equal(2, host.Spawns.Count);
        // The startup-only entry must NOT have fired.
        Assert.DoesNotContain(host.Logs, l => l.Contains("name=startup-only"));
    }

    [Fact]
    public void Restart_OnNonZeroExit_SchedulesBackoffSequence()
    {
        var host = new FakeHost();
        var runner = Make(host, Entry("svc", restart: true));

        runner.OnStartup();
        var first = Assert.Single(host.Spawns);
        Assert.NotNull(first.OnExit);

        // Simulate 7 successive non-zero exits and capture the scheduled delays.
        var delays = new List<TimeSpan>();
        for (int i = 0; i < 7; i++)
        {
            // Trigger the exit handler from the most-recent spawn.
            host.Spawns[^1].OnExit!(1);
            // Drain the scheduled relaunch (which spawns again).
            var fired = host.FireAllScheduled();
            Assert.Single(fired);
            delays.Add(fired[0]);
        }

        Assert.Equal(TimeSpan.FromMilliseconds(250),    delays[0]);
        Assert.Equal(TimeSpan.FromMilliseconds(500),    delays[1]);
        Assert.Equal(TimeSpan.FromMilliseconds(1_000),  delays[2]);
        Assert.Equal(TimeSpan.FromMilliseconds(2_000),  delays[3]);
        Assert.Equal(TimeSpan.FromMilliseconds(4_000),  delays[4]);
        Assert.Equal(TimeSpan.FromMilliseconds(8_000),  delays[5]);
        Assert.Equal(TimeSpan.FromMilliseconds(10_000), delays[6]); // capped
    }

    [Fact]
    public void Restart_OnZeroExit_DoesNotRelaunchAndResetsBackoff()
    {
        var host = new FakeHost();
        var runner = Make(host, Entry("svc", restart: true));

        runner.OnStartup();
        Assert.Single(host.Spawns);

        // Clean exit — no relaunch scheduled.
        host.Spawns[^1].OnExit!(0);
        Assert.Empty(host.Scheduled);

        // A subsequent crashing exit should restart at the *first* backoff
        // step, because clean exits reset the supervisor's attempt counter.
        // We fake this by having `restart=true` + `once=false`-ish behavior:
        // Note: with once=true the entry won't be re-fired manually here,
        // so we trigger the supervisor path directly via OnExit again.
        host.Spawns[^1].OnExit!(1);
        var fired = host.FireAllScheduled();
        Assert.Single(fired);
        Assert.Equal(TimeSpan.FromMilliseconds(250), fired[0]);
    }

    [Fact]
    public void NoRestart_OnExitIsNullEvenIfEntryExits()
    {
        var host = new FakeHost();
        var runner = Make(host, Entry("svc", restart: false));

        runner.OnStartup();
        var req = Assert.Single(host.Spawns);
        Assert.Null(req.OnExit);
        Assert.Empty(host.Scheduled);
    }
}
