using System;
using System.Collections.Generic;
using System.Linq;
using Aqueous.Features.Layout;
using Aqueous.Features.State;

namespace Aqueous.Features.Startup;

/// <summary>
/// Phase B1f — fires <c>[[exec]]</c> autostart entries from <c>wm.toml</c>
/// after the compositor has advertised its globals. Idempotent per
/// <see cref="ExecEntry.Once"/>; supervises <see cref="ExecEntry.Restart"/>
/// children with exponential backoff (250 ms → 500 → 1 s → 2 s → 4 s →
/// 8 s → cap 10 s, reset on a clean exit).
/// </summary>
internal sealed class StartupExecRunner
{
    private readonly IWindowStateHost _host;
    private readonly ExecConfig _cfg;
    private readonly HashSet<string> _firedOnce = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Supervisor> _supervised = new(StringComparer.Ordinal);
    private readonly object _gate = new();

    public StartupExecRunner(IWindowStateHost host, ExecConfig cfg)
    {
        _host = host ?? throw new ArgumentNullException(nameof(host));
        _cfg = cfg ?? throw new ArgumentNullException(nameof(cfg));
    }

    /// <summary>Fires entries with <c>when = startup</c> or <c>when = always</c>.</summary>
    public void OnStartup() => Fire(e => e.When is ExecWhen.Startup or ExecWhen.Always);

    /// <summary>Fires entries with <c>when = reload</c> or <c>when = always</c>.</summary>
    public void OnReload() => Fire(e => e.When is ExecWhen.Reload or ExecWhen.Always);

    private void Fire(Func<ExecEntry, bool> predicate)
    {
        foreach (var e in _cfg.Entries.Where(predicate))
        {
            lock (_gate)
            {
                if (e.Once && !_firedOnce.Add(e.Name))
                {
                    continue;
                }
            }
            Launch(e);
        }
    }

    private void Launch(ExecEntry e)
    {
        _host.Log($"exec name={e.Name} when={e.When} cmd={e.Command}");
        var req = new SpawnRequest(
            Command: e.Command,
            LogPath: e.LogPath,
            Env: e.Env,
            OnExit: e.Restart ? code => OnExited(e, code) : null);
        _host.Spawn(req);
    }

    private void OnExited(ExecEntry e, int code)
    {
        Supervisor s;
        lock (_gate)
        {
            if (!_supervised.TryGetValue(e.Name, out var existing))
            {
                _supervised[e.Name] = existing = new Supervisor();
            }
            s = existing;
            if (code == 0)
            {
                // Clean exit — treat as user-terminated; reset attempt
                // counter and don't relaunch.
                s.Reset();
                _host.Log($"exec name={e.Name} exited code=0 (no restart)");
                return;
            }
        }

        var delay = s.NextBackoff();
        _host.Log($"exec name={e.Name} exited code={code} restart_in={delay.TotalMilliseconds}ms");
        _host.ScheduleAfter(delay, () => Launch(e));
    }

    /// <summary>
    /// Per-entry restart-attempt counter. The 7-step ladder is exposed
    /// for tests via the public <see cref="NextBackoff"/> method.
    /// </summary>
    internal sealed class Supervisor
    {
        private int _attempt;

        public TimeSpan NextBackoff()
        {
            // 250 * 2^attempt, clamped at 10 s. Sequence:
            // 250, 500, 1 000, 2 000, 4 000, 8 000, 10 000, 10 000, …
            var attempt = Math.Min(_attempt, 6);
            _attempt++;
            var ms = Math.Min(10_000, 250 * (1 << attempt));
            return TimeSpan.FromMilliseconds(ms);
        }

        public void Reset() => _attempt = 0;
    }
}
