using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace Aqueous.OutputDaemon;

/// <summary>
/// Thin wrapper around the <c>wlr-randr</c> CLI.
/// All argv is built explicitly (no shell), so user-supplied output names
/// and modes are passed as separate <c>ArgumentList</c> entries.
/// </summary>
internal static class WlrRandr
{
    public sealed class Mode
    {
        public int Width;
        public int Height;
        public double Refresh;       // Hz
        public bool Preferred;
        public bool Current;
    }

    public sealed class Output
    {
        public string Name = "";
        public string? Make;
        public string? Model;
        public string? Serial;
        public string? EdidSha256;
        public bool Enabled;
        public int X;
        public int Y;
        public double Scale = 1.0;
        public string Transform = "normal";
        public bool? AdaptiveSync;
        public Mode? CurrentMode;
        public List<Mode> Modes = new();
    }

    /// <summary>Run <c>wlr-randr --json</c> and parse the result.</summary>
    public static List<Output> List(out string? error)
    {
        error = null;
        var (rc, stdout, stderr) = Run(new[] { "--json" });
        if (rc != 0)
        {
            error = stderr.Trim();
            return new List<Output>();
        }
        try
        {
            return ParseJson(stdout);
        }
        catch (Exception ex)
        {
            error = "parse: " + ex.Message;
            return new List<Output>();
        }
    }

    public static List<Output> ParseJson(string json)
    {
        var arr = Json.ParseArray(json) ?? new List<object?>();
        var outs = new List<Output>(arr.Count);
        foreach (var o in arr)
        {
            if (o is not Dictionary<string, object?> d) continue;
            var op = new Output();
            op.Name = d.GetString("name") ?? "";
            op.Make = d.GetString("make");
            op.Model = d.GetString("model");
            op.Serial = d.GetString("serial_number") ?? d.GetString("serial");
            op.Enabled = d.GetBool("enabled") ?? true;

            // Position lives under "position": {"x":..,"y":..} on newer wlr-randr
            // and under top-level x/y on older builds.
            if (d.TryGetValue("position", out var posObj) && posObj is Dictionary<string, object?> pd)
            {
                op.X = (int)(pd.GetDouble("x") ?? 0);
                op.Y = (int)(pd.GetDouble("y") ?? 0);
            }
            else
            {
                op.X = (int)(d.GetDouble("x") ?? 0);
                op.Y = (int)(d.GetDouble("y") ?? 0);
            }

            op.Scale = d.GetDouble("scale") ?? 1.0;
            op.Transform = d.GetString("transform") ?? "normal";
            op.AdaptiveSync = d.GetBool("adaptive_sync");

            if (d.TryGetValue("modes", out var modesObj) && modesObj is List<object?> ml)
            {
                foreach (var m in ml)
                {
                    if (m is not Dictionary<string, object?> md) continue;
                    var mode = new Mode
                    {
                        Width = (int)(md.GetDouble("width") ?? 0),
                        Height = (int)(md.GetDouble("height") ?? 0),
                        Refresh = (md.GetDouble("refresh") ?? 0.0),
                        Preferred = md.GetBool("preferred") ?? false,
                        Current = md.GetBool("current") ?? false,
                    };
                    // wlr-randr reports refresh in mHz; normalize to Hz.
                    if (mode.Refresh > 1000) mode.Refresh /= 1000.0;
                    op.Modes.Add(mode);
                    if (mode.Current) op.CurrentMode = mode;
                }
            }

            // EDID identification: hash make/model/serial if present.
            op.EdidSha256 = ComputeEdidHash(op);
            outs.Add(op);
        }
        return outs;
    }

    public static string? ComputeEdidHash(Output o)
    {
        if (string.IsNullOrEmpty(o.Make) && string.IsNullOrEmpty(o.Model) && string.IsNullOrEmpty(o.Serial))
            return null;
        var s = $"{o.Make}|{o.Model}|{o.Serial}";
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(s));
        var sb = new StringBuilder("sha256:", 8 + bytes.Length * 2);
        foreach (var b in bytes) sb.Append(b.ToString("x2", CultureInfo.InvariantCulture));
        return sb.ToString();
    }

    /// <summary>
    /// Build and run a single <c>wlr-randr</c> invocation that applies all
    /// changes atomically (one KMS commit).
    /// </summary>
    public static (int rc, string stdout, string stderr) Apply(IEnumerable<OutputChange> changes)
    {
        var args = new List<string>();
        foreach (var c in changes)
        {
            if (string.IsNullOrEmpty(c.Name)) continue;
            args.Add("--output"); args.Add(c.Name);
            if (c.Enabled is bool en) args.Add(en ? "--on" : "--off");
            if (!string.IsNullOrEmpty(c.Mode)) { args.Add("--mode"); args.Add(c.Mode!); }
            if (c.Scale is double sc) { args.Add("--scale"); args.Add(sc.ToString("R", CultureInfo.InvariantCulture)); }
            if (!string.IsNullOrEmpty(c.Transform)) { args.Add("--transform"); args.Add(c.Transform!); }
            if (c.Position is (int x, int y))
            {
                args.Add("--pos");
                args.Add(string.Create(CultureInfo.InvariantCulture, $"{x},{y}"));
            }
            if (c.AdaptiveSync is bool vrr)
            {
                args.Add("--adaptive-sync");
                args.Add(vrr ? "enabled" : "disabled");
            }
        }
        if (args.Count == 0) return (0, "", "");
        return Run(args);
    }

    public static (int rc, string stdout, string stderr) Run(IEnumerable<string> args)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "wlr-randr",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        try
        {
            using var p = Process.Start(psi)!;
            string stdout = p.StandardOutput.ReadToEnd();
            string stderr = p.StandardError.ReadToEnd();
            p.WaitForExit(15_000);
            return (p.ExitCode, stdout, stderr);
        }
        catch (Exception ex)
        {
            return (-1, "", "spawn: " + ex.Message);
        }
    }
}

/// <summary>
/// One pending change to one output. Any field that is null means
/// "do not touch".
/// </summary>
internal sealed class OutputChange
{
    public string Name = "";              // resolved connector name
    public bool? Enabled;
    public string? Mode;                  // "WxH[@Hz]"
    public double? Scale;
    public string? Transform;
    public (int X, int Y)? Position;
    public bool? AdaptiveSync;
}

internal static class JsonExtensions
{
    public static string? GetString(this Dictionary<string, object?> d, string k)
        => d.TryGetValue(k, out var v) ? v as string : null;

    public static double? GetDouble(this Dictionary<string, object?> d, string k)
    {
        if (!d.TryGetValue(k, out var v) || v is null) return null;
        return v switch
        {
            double dd => dd,
            int i => i,
            long l => l,
            string s when double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var p) => p,
            _ => null,
        };
    }

    public static bool? GetBool(this Dictionary<string, object?> d, string k)
        => d.TryGetValue(k, out var v) ? v as bool? : null;
}
