using System;
using System.Collections.Generic;

namespace Aqueous.Features.Layout;

/// <summary>
/// Lifecycle predicate for an <see cref="ExecEntry"/> — when, during the
/// WM's lifetime, the entry should be launched.
/// </summary>
public enum ExecWhen
{
    /// <summary>Fire once after Aqueous finishes its initial roundtrip with the compositor.</summary>
    Startup,
    /// <summary>Fire on every config reload (SIGUSR1 / file watcher).</summary>
    Reload,
    /// <summary>Fire on both startup and reload.</summary>
    Always,
}

/// <summary>
/// One <c>[[exec]]</c> table parsed from <c>wm.toml</c>. Describes a
/// supervised autostart command — the bar, a wallpaper daemon, a polkit
/// agent, etc. — that Aqueous owns and (optionally) restarts.
/// </summary>
public sealed record ExecEntry
{
    /// <summary>Identifier used for logs, de-duplication, and IPC queries.</summary>
    public required string Name { get; init; }

    /// <summary>Shell command, passed to <c>/bin/sh -c</c> and detached via <c>setsid</c>.</summary>
    public required string Command { get; init; }

    /// <summary>When this entry fires. Defaults to <see cref="ExecWhen.Startup"/>.</summary>
    public ExecWhen When { get; init; } = ExecWhen.Startup;

    /// <summary>If true, suppress duplicate launches per Aqueous lifetime.</summary>
    public bool Once { get; init; } = true;

    /// <summary>If true, respawn (with backoff) on non-zero exit.</summary>
    public bool Restart { get; init; }

    /// <summary>Optional path to redirect stdout+stderr to. Null → <c>/dev/null</c>.</summary>
    public string? LogPath { get; init; }

    /// <summary>Per-entry environment overrides; merged on top of inherited env.</summary>
    public IReadOnlyDictionary<string, string> Env { get; init; }
        = new Dictionary<string, string>(StringComparer.Ordinal);
}

/// <summary>
/// Top-level <c>[[exec]]</c> section of <c>wm.toml</c>. A flat list of
/// <see cref="ExecEntry"/> records, evaluated in declaration order.
/// </summary>
public sealed record ExecConfig
{
    public IReadOnlyList<ExecEntry> Entries { get; init; } = Array.Empty<ExecEntry>();

    public static ExecConfig Empty { get; } = new();
}
