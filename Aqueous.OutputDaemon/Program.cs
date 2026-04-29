using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Aqueous.OutputDaemon;

/// <summary>
/// <c>aqueous-outputd</c> — session-scoped output configuration sidecar
/// for Aqueous/River.
/// <para>
/// River 0.4 exposes no in-process output-management protocol to a WM
/// client, and <c>wlr-randr</c> only works inside River's <c>-c</c>
/// control context. This daemon parks itself there (launched from
/// <c>aqueous-init</c> which River exec's via <c>river -c</c>), owns
/// the only mouth that can talk to wlroots's output manager, and fans
/// that capability out over a Unix socket to:
/// <list type="bullet">
///   <item>Aqueous itself (live mode/scale changes from <c>wm.toml</c>),</item>
///   <item>shells like Noctalia (display panel UI),</item>
///   <item><c>aqueous-init</c> at session start (fixes the greetd
///         render-size bug by applying persisted config before Aqueous
///         draws its first frame).</item>
/// </list>
/// </para>
/// <para>
/// Two run modes:
/// <list type="bullet">
///   <item><c>--apply-once</c>: read <c>wm.toml</c> + <c>outputs.toml</c>,
///         apply via one <c>wlr-randr</c> call, exit.</item>
///   <item><c>--serve</c> (default): listen on
///         <c>$XDG_RUNTIME_DIR/aqueous/outputd.sock</c> for JSON requests.</item>
/// </list>
/// </para>
/// </summary>
internal static class Program
{
    // ---- shared state (guarded by _lock) -------------------------------

    private static readonly object _lock = new();
    private static List<WlrRandr.Output> _snapshot = new();
    private static readonly HashSet<Subscriber> _subscribers = new();
    private static string? _activeProfile;

    private const int ProtocolVersion = 1;

    // ---- entry ---------------------------------------------------------

    private static int Main(string[] args)
    {
        var (mode, configPath, profile) = ParseArgs(args);
        Log($"starting (mode={mode} config={configPath ?? "-"} profile={profile ?? "-"})");

        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("WAYLAND_DISPLAY")))
        {
            Log("WAYLAND_DISPLAY is not set — refusing to start (must run inside River's control context)");
            return 2;
        }

        return mode switch
        {
            "version"    => CmdVersion(),
            "apply-once" => CmdApplyOnce(configPath, profile),
            "serve"      => CmdServe(configPath),
            _            => CmdUsage(),
        };
    }

    private static int CmdVersion()
    {
        Console.WriteLine($"aqueous-outputd 0.0.1 protocol={ProtocolVersion}");
        return 0;
    }

    private static int CmdUsage()
    {
        Console.Error.WriteLine(
            "usage: aqueous-outputd [--serve | --apply-once] [--config PATH] [--profile NAME]");
        return 64;
    }

    // ---- --apply-once --------------------------------------------------

    private static int CmdApplyOnce(string? configPath, string? profileName)
    {
        var (cfg, persisted) = LoadConfigs(configPath);
        var snap = WlrRandr.List(out var listErr);
        if (snap.Count == 0)
        {
            Log("apply-once: wlr-randr returned no outputs" + (listErr is null ? "" : $" ({listErr})"));
            return 0; // never block session start
        }

        // Choose source of truth: explicit profile arg → cfg.Profiles[name]
        // → cfg.Outputs (top-level [[output]]) → persisted outputs.toml.
        List<TomlConfig.OutputSpec> source = ResolveSource(cfg, persisted, profileName, out var sourceLabel);
        if (source.Count == 0)
        {
            Log("apply-once: no [[output]] entries in config; nothing to do");
            return 0;
        }
        Log($"apply-once: using {sourceLabel} ({source.Count} entries)");

        var changes = new List<OutputChange>();
        foreach (var spec in source)
        {
            var dict = spec.ToDict();
            var ch = Validator.Resolve(dict, snap, out var err);
            if (ch is null) { Log($"apply-once: skip — {err}"); continue; }
            changes.Add(ch);
        }

        if (changes.Count == 0)
        {
            Log("apply-once: nothing valid to apply");
            return 0;
        }

        var (rc, _, stderr) = WlrRandr.Apply(changes);
        if (rc != 0)
        {
            Log($"apply-once: wlr-randr failed rc={rc} stderr={stderr.Trim()}");
            // Try fallback profile.
            if (cfg?.Display.FallbackProfile is { } fb && !string.Equals(fb, profileName, StringComparison.Ordinal))
            {
                Log($"apply-once: trying fallback_profile='{fb}'");
                return CmdApplyOnce(configPath, fb);
            }
            return 0; // non-fatal: never block session start
        }
        Log("apply-once: ok");
        return 0;
    }

    private static List<TomlConfig.OutputSpec> ResolveSource(
        TomlConfig? cfg, TomlConfig? persisted, string? profileName, out string label)
    {
        if (cfg is not null && !string.IsNullOrEmpty(profileName))
        {
            foreach (var p in cfg.Profiles)
                if (string.Equals(p.Name, profileName, StringComparison.Ordinal))
                { label = $"profile '{profileName}'"; return p.Outputs; }
            label = "profile-not-found";
            return new();
        }
        if (cfg is not null && cfg.Outputs.Count > 0)
        {
            // Only entries that carry display-side fields.
            var withFields = cfg.Outputs.Where(HasAnyDisplayField).ToList();
            if (withFields.Count > 0) { label = "wm.toml [[output]]"; return withFields; }
        }
        if (persisted is not null && persisted.Outputs.Count > 0)
        {
            label = "outputs.toml"; return persisted.Outputs;
        }
        label = "(none)";
        return new();
    }

    private static bool HasAnyDisplayField(TomlConfig.OutputSpec o)
        => o.Mode is not null || o.Scale is not null || o.Transform is not null ||
           o.Position is not null || o.Enabled is not null || o.AdaptiveSync is not null;

    // ---- --serve -------------------------------------------------------

    private static int CmdServe(string? configPath)
    {
        var sockPath = SocketPath();
        try { Directory.CreateDirectory(Path.GetDirectoryName(sockPath)!); } catch { }
        try { File.Delete(sockPath); } catch { }
        var listener = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        listener.Bind(new UnixDomainSocketEndPoint(sockPath));
        listener.Listen(16);
        try { File.SetUnixFileMode(sockPath, UnixFileMode.UserRead | UnixFileMode.UserWrite); } catch { }
        Log($"listening on {sockPath}");

        // Initial snapshot.
        RefreshSnapshot();

        var cts = new CancellationTokenSource();
        Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };
        AppDomain.CurrentDomain.ProcessExit += (_, _) => cts.Cancel();

        // Hotplug poll: only when at least one subscriber is connected.
        _ = Task.Run(() => HotplugLoop(cts.Token));

        try
        {
            AcceptLoop(listener, configPath, cts.Token).GetAwaiter().GetResult();
        }
        catch (OperationCanceledException) { }
        finally
        {
            listener.Close();
            try { File.Delete(sockPath); } catch { }
        }
        Log("shutting down");
        return 0;
    }

    private static async Task AcceptLoop(Socket listener, string? configPath, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            Socket client;
            try { client = await listener.AcceptAsync(ct); }
            catch (OperationCanceledException) { return; }
            catch { return; }
            _ = Task.Run(() => HandleClient(client, configPath, ct), ct);
        }
    }

    private static async Task HandleClient(Socket client, string? configPath, CancellationToken ct)
    {
        Subscriber? sub = null;
        try
        {
            using var _ = client;
            // PeerCred check: refuse foreign UIDs.
            if (!CheckPeerCred(client))
            {
                Log("rejected: foreign-uid client");
                return;
            }
            using var stream = new NetworkStream(client, ownsSocket: false);
            using var reader = new StreamReader(stream, Encoding.UTF8, false, 8192, leaveOpen: true);
            using var writer = new StreamWriter(stream, new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" };

            while (!ct.IsCancellationRequested)
            {
                string? line = await reader.ReadLineAsync(ct).ConfigureAwait(false);
                if (line is null) return;
                if (line.Length == 0) continue;

                Dictionary<string, object?>? req;
                try { req = Json.ParseObject(line); }
                catch (Exception ex)
                {
                    await writer.WriteLineAsync(Json.Write(new Dictionary<string, object?>
                        { ["ok"] = false, ["error"] = "bad json: " + ex.Message }));
                    continue;
                }
                if (req is null)
                {
                    await writer.WriteLineAsync(Json.Write(new Dictionary<string, object?>
                        { ["ok"] = false, ["error"] = "expected object" }));
                    continue;
                }

                string op = req.GetString("op") ?? "";
                Dictionary<string, object?> resp;
                switch (op)
                {
                    case "version":
                        resp = new() {
                            ["ok"] = true, ["daemon"] = "aqueous-outputd",
                            ["version"] = "0.0.1", ["protocol"] = ProtocolVersion,
                        };
                        break;
                    case "list":
                        RefreshSnapshot();
                        resp = new() { ["ok"] = true, ["outputs"] = SnapshotToJson() };
                        break;
                    case "set":
                        resp = HandleSet(req);
                        break;
                    case "apply_profile":
                        resp = HandleApplyProfile(req, configPath);
                        break;
                    case "save_profile":
                        resp = HandleSaveProfile(req);
                        break;
                    case "reload":
                        resp = HandleReload(configPath);
                        break;
                    case "subscribe":
                        sub = new Subscriber(writer);
                        lock (_lock) _subscribers.Add(sub);
                        resp = new() { ["ok"] = true, ["subscribed"] = true };
                        break;
                    default:
                        resp = new() { ["ok"] = false, ["error"] = $"unknown op '{op}'" };
                        break;
                }

                await writer.WriteLineAsync(Json.Write(resp));

                // After a subscribe response, keep the connection open and
                // pump events from the subscriber's queue.
                if (sub is not null)
                {
                    await PumpSubscriber(sub, writer, ct);
                    return;
                }
            }
        }
        catch (Exception ex)
        {
            Log("client error: " + ex.Message);
        }
        finally
        {
            if (sub is not null)
            {
                lock (_lock) _subscribers.Remove(sub);
            }
        }
    }

    private static async Task PumpSubscriber(Subscriber sub, StreamWriter writer, CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var ev = await sub.Events.Reader.ReadAsync(ct).ConfigureAwait(false);
                await writer.WriteLineAsync(ev);
            }
        }
        catch { /* fall through to cleanup */ }
    }

    // ---- ops -----------------------------------------------------------

    private static Dictionary<string, object?> HandleSet(Dictionary<string, object?> req)
    {
        if (!req.TryGetValue("changes", out var ch) || ch is not List<object?> arr)
            return new() { ["ok"] = false, ["error"] = "missing 'changes' array" };

        RefreshSnapshot();
        List<WlrRandr.Output> snap;
        lock (_lock) snap = _snapshot;

        var resolved = new List<OutputChange>();
        foreach (var item in arr)
        {
            if (item is not Dictionary<string, object?> spec)
                return new() { ["ok"] = false, ["error"] = "change must be an object", ["stage"] = "validate" };
            var c = Validator.Resolve(spec, snap, out var err);
            if (c is null)
                return new() { ["ok"] = false, ["error"] = err, ["stage"] = "validate" };
            resolved.Add(c);
        }

        var (rc, _, stderr) = WlrRandr.Apply(resolved);
        if (rc != 0)
        {
            // Best-effort rollback: re-run wlr-randr with snapshot values.
            RollbackTo(snap, resolved);
            return new() {
                ["ok"] = false, ["error"] = stderr.Trim(),
                ["stage"] = "apply", ["rolled_back"] = true,
            };
        }

        RefreshSnapshot();
        BroadcastOutputChanged();

        return new() {
            ["ok"] = true,
            ["applied"] = resolved.Count,
            ["outputs"] = SnapshotToJson(),
        };
    }

    private static void RollbackTo(IReadOnlyList<WlrRandr.Output> prev, IEnumerable<OutputChange> changed)
    {
        var rollback = new List<OutputChange>();
        foreach (var c in changed)
        {
            var p = prev.FirstOrDefault(o => o.Name == c.Name);
            if (p is null) continue;
            rollback.Add(new OutputChange
            {
                Name = p.Name,
                Enabled = p.Enabled,
                Mode = p.CurrentMode is { } m
                    ? string.Create(CultureInfo.InvariantCulture, $"{m.Width}x{m.Height}@{m.Refresh:0.###}")
                    : null,
                Scale = p.Scale,
                Transform = p.Transform,
                Position = (p.X, p.Y),
                AdaptiveSync = p.AdaptiveSync,
            });
        }
        if (rollback.Count > 0) WlrRandr.Apply(rollback);
    }

    private static Dictionary<string, object?> HandleApplyProfile(Dictionary<string, object?> req, string? configPath)
    {
        var name = req.GetString("name");
        if (string.IsNullOrEmpty(name))
            return new() { ["ok"] = false, ["error"] = "missing 'name'" };
        var (cfg, _) = LoadConfigs(configPath);
        if (cfg is null)
            return new() { ["ok"] = false, ["error"] = "config not loaded" };
        TomlConfig.Profile? profile = cfg.Profiles.FirstOrDefault(p => p.Name == name);
        if (profile is null)
            return new() { ["ok"] = false, ["error"] = $"unknown profile '{name}'" };

        // Translate to a 'set' request and reuse HandleSet.
        var changes = new List<object?>();
        foreach (var o in profile.Outputs) changes.Add(o.ToDict());
        var resp = HandleSet(new Dictionary<string, object?> { ["changes"] = changes });
        if (resp.TryGetValue("ok", out var okV) && okV is true)
        {
            lock (_lock) _activeProfile = name;
            BroadcastEvent(new() {
                ["event"] = "profile-changed",
                ["data"] = new Dictionary<string, object?> { ["name"] = name },
            });
        }
        return resp;
    }

    private static Dictionary<string, object?> HandleSaveProfile(Dictionary<string, object?> req)
    {
        var name = req.GetString("name");
        if (string.IsNullOrEmpty(name))
            return new() { ["ok"] = false, ["error"] = "missing 'name'" };
        if (!req.TryGetValue("outputs", out var outsObj) || outsObj is not List<object?> outs)
            return new() { ["ok"] = false, ["error"] = "missing 'outputs' array" };

        try
        {
            var path = OutputsTomlPath();
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var sb = new StringBuilder();
            // Append (or create) a [[display.profile]] block. We never
            // rewrite existing entries — keep the file diff-friendly.
            if (File.Exists(path)) sb.Append(File.ReadAllText(path));
            sb.AppendLine();
            sb.AppendLine("[[display.profile]]");
            sb.AppendLine($"name = \"{Escape(name!)}\"");
            foreach (var o in outs)
            {
                if (o is not Dictionary<string, object?> d) continue;
                sb.AppendLine();
                sb.AppendLine("[[display.profile.output]]");
                foreach (var (k, v) in d)
                    sb.AppendLine(SerializeKv(k, v));
            }
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, sb.ToString());
            File.Move(tmp, path, overwrite: true);
            return new() { ["ok"] = true, ["path"] = path };
        }
        catch (Exception ex)
        {
            return new() { ["ok"] = false, ["error"] = "write: " + ex.Message };
        }
    }

    private static string SerializeKv(string k, object? v) => v switch
    {
        string s => $"{k} = \"{Escape(s)}\"",
        bool b   => $"{k} = {(b ? "true" : "false")}",
        double d => $"{k} = {d.ToString("R", CultureInfo.InvariantCulture)}",
        int i    => $"{k} = {i.ToString(CultureInfo.InvariantCulture)}",
        List<object?> arr => $"{k} = [{string.Join(", ", arr.Select(x => x?.ToString() ?? "null"))}]",
        _ => $"{k} = \"{Escape(v?.ToString() ?? "")}\"",
    };

    private static string Escape(string s) =>
        s.Replace("\\", "\\\\").Replace("\"", "\\\"");

    private static Dictionary<string, object?> HandleReload(string? configPath)
    {
        // Just refresh snapshot; the config is re-read on demand by --apply-once
        // and apply_profile. Surface that the reload happened.
        RefreshSnapshot();
        BroadcastOutputChanged();
        return new() { ["ok"] = true };
    }

    // ---- snapshot + broadcast -----------------------------------------

    private static void RefreshSnapshot()
    {
        var snap = WlrRandr.List(out _);
        lock (_lock) _snapshot = snap;
    }

    private static List<object?> SnapshotToJson()
    {
        List<WlrRandr.Output> snap;
        lock (_lock) snap = _snapshot;
        var arr = new List<object?>(snap.Count);
        foreach (var o in snap)
        {
            var modes = new List<object?>(o.Modes.Count);
            foreach (var m in o.Modes)
                modes.Add(new Dictionary<string, object?>
                {
                    ["width"] = (double)m.Width,
                    ["height"] = (double)m.Height,
                    ["refresh"] = m.Refresh,
                    ["preferred"] = m.Preferred,
                    ["current"] = m.Current,
                });
            arr.Add(new Dictionary<string, object?>
            {
                ["name"] = o.Name,
                ["make"] = o.Make,
                ["model"] = o.Model,
                ["serial"] = o.Serial,
                ["edid_sha256"] = o.EdidSha256,
                ["enabled"] = o.Enabled,
                ["x"] = (double)o.X,
                ["y"] = (double)o.Y,
                ["scale"] = o.Scale,
                ["transform"] = o.Transform,
                ["adaptive_sync"] = o.AdaptiveSync,
                ["current_mode"] = o.CurrentMode is { } cm
                    ? new Dictionary<string, object?>
                    {
                        ["width"] = (double)cm.Width,
                        ["height"] = (double)cm.Height,
                        ["refresh"] = cm.Refresh,
                    }
                    : null,
                ["modes"] = modes,
            });
        }
        return arr;
    }

    private static void BroadcastOutputChanged()
    {
        BroadcastEvent(new() {
            ["event"] = "output-changed",
            ["data"] = new Dictionary<string, object?> { ["outputs"] = SnapshotToJson() },
        });
    }

    private static void BroadcastEvent(Dictionary<string, object?> ev)
    {
        var line = Json.Write(ev);
        Subscriber[] snap;
        lock (_lock) snap = _subscribers.ToArray();
        foreach (var s in snap)
            s.Events.Writer.TryWrite(line);
    }

    // ---- hotplug poll --------------------------------------------------

    private static async Task HotplugLoop(CancellationToken ct)
    {
        var prevNames = new HashSet<string>(StringComparer.Ordinal);
        while (!ct.IsCancellationRequested)
        {
            try
            {
                bool any;
                lock (_lock) any = _subscribers.Count > 0;
                if (any)
                {
                    var snap = WlrRandr.List(out _);
                    var cur = new HashSet<string>(snap.Select(o => o.Name), StringComparer.Ordinal);
                    var added = cur.Except(prevNames).ToList();
                    var removed = prevNames.Except(cur).ToList();
                    if (added.Count > 0 || removed.Count > 0)
                    {
                        lock (_lock) _snapshot = snap;
                        BroadcastEvent(new() {
                            ["event"] = "hotplug",
                            ["data"] = new Dictionary<string, object?>
                            {
                                ["added"] = added.Cast<object?>().ToList(),
                                ["removed"] = removed.Cast<object?>().ToList(),
                            },
                        });
                        BroadcastOutputChanged();
                    }
                    prevNames = cur;
                }
                await Task.Delay(500, ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { return; }
            catch (Exception ex) { Log("hotplug: " + ex.Message); await Task.Delay(2000, ct); }
        }
    }

    // ---- config loading ------------------------------------------------

    private static (TomlConfig? cfg, TomlConfig? persisted) LoadConfigs(string? configPath)
    {
        var cfg = configPath is not null ? TomlConfig.Load(configPath) : null;
        if (cfg is null)
        {
            // Fallback search.
            var home = Environment.GetEnvironmentVariable("HOME") ?? "";
            var xdg = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME");
            if (string.IsNullOrEmpty(xdg)) xdg = Path.Combine(home, ".config");
            cfg = TomlConfig.Load(Path.Combine(xdg, "aqueous", "wm.toml"))
               ?? TomlConfig.Load("/etc/xdg/aqueous/wm.toml");
        }
        var persisted = TomlConfig.Load(OutputsTomlPath());
        return (cfg, persisted);
    }

    private static string OutputsTomlPath()
    {
        var xdg = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME");
        if (string.IsNullOrEmpty(xdg))
            xdg = Path.Combine(Environment.GetEnvironmentVariable("HOME") ?? "", ".config");
        return Path.Combine(xdg, "aqueous", "outputs.toml");
    }

    // ---- helpers -------------------------------------------------------

    private static (string mode, string? configPath, string? profile) ParseArgs(string[] args)
    {
        string mode = "serve";
        string? cfg = null;
        string? profile = null;
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--apply-once": mode = "apply-once"; break;
                case "--serve":      mode = "serve"; break;
                case "--version":    mode = "version"; break;
                case "--config":     if (i + 1 < args.Length) cfg = args[++i]; break;
                case "--profile":    if (i + 1 < args.Length) profile = args[++i]; break;
            }
        }
        return (mode, cfg, profile);
    }

    private static string SocketPath()
    {
        var rt = Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR");
        if (string.IsNullOrEmpty(rt)) rt = "/tmp";
        return Path.Combine(rt, "aqueous", "outputd.sock");
    }

    private static void Log(string msg) =>
        Console.WriteLine($"[aqueous-outputd] {msg}");

    // ---- SO_PEERCRED ---------------------------------------------------

    [StructLayout(LayoutKind.Sequential)]
    private struct Ucred
    {
        public int pid;
        public uint uid;
        public uint gid;
    }

    private const int SOL_SOCKET = 1;
    private const int SO_PEERCRED = 17;

    [DllImport("libc", SetLastError = true)]
    private static extern int getsockopt(int sockfd, int level, int optname, ref Ucred optval, ref uint optlen);

    private static bool CheckPeerCred(Socket s)
    {
        try
        {
            var fd = (int)s.Handle;
            var cred = default(Ucred);
            uint len = (uint)Marshal.SizeOf<Ucred>();
            int rc = getsockopt(fd, SOL_SOCKET, SO_PEERCRED, ref cred, ref len);
            if (rc != 0) return true; // not Linux? skip — best-effort hardening
            uint myUid = (uint)getuid();
            return cred.uid == myUid;
        }
        catch
        {
            return true;
        }
    }

    [DllImport("libc")]
    private static extern int getuid();

    // ---- subscriber ----------------------------------------------------

    private sealed class Subscriber
    {
        public readonly System.Threading.Channels.Channel<string> Events =
            System.Threading.Channels.Channel.CreateUnbounded<string>(
                new System.Threading.Channels.UnboundedChannelOptions { SingleReader = true, SingleWriter = false });
        public Subscriber(StreamWriter _) { }
    }
}
