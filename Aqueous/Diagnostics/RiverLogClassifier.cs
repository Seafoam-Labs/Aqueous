using System;
using Microsoft.Extensions.Logging;

namespace Aqueous.Diagnostics;

/// <summary>
/// PR 9.12 §2.12 — pure helper that classifies a free-form River log
/// message into a <see cref="LogLevel"/> based on small content
/// heuristics. Previously lived as <c>RiverWindowManagerClient.ClassifyLogLevel</c>;
/// lifted top-level so the god-class can shed all logging concerns and
/// new call sites can route through a stable seam. Behaviour is
/// byte-for-byte equivalent to the prior implementation.
/// </summary>
internal static class RiverLogClassifier
{
    /// <summary>
    /// Map a free-form River protocol log message to a <see cref="LogLevel"/>
    /// using prefix-/substring-based heuristics that exploit the
    /// distinguishing tokens already present at every emit site
    /// (<c>ERROR</c>, <c>failed</c>, <c>warn</c>, <c>unavailable</c>,
    /// <c>connected</c>, <c>disconnect</c>, …).
    /// </summary>
    public static LogLevel Classify(string msg)
    {
        if (string.IsNullOrEmpty(msg)) return LogLevel.Debug;
        if (msg.Contains("ERROR", StringComparison.OrdinalIgnoreCase) ||
            msg.Contains("failed", StringComparison.OrdinalIgnoreCase) ||
            msg.Contains("could not", StringComparison.OrdinalIgnoreCase))
            return LogLevel.Error;
        if (msg.Contains("warn", StringComparison.OrdinalIgnoreCase) ||
            msg.Contains("unavailable", StringComparison.OrdinalIgnoreCase) ||
            msg.Contains("giving up", StringComparison.OrdinalIgnoreCase))
            return LogLevel.Warning;
        if (msg.Contains("connected", StringComparison.OrdinalIgnoreCase) ||
            msg.Contains("disconnect", StringComparison.OrdinalIgnoreCase) ||
            msg.Contains("manage_start", StringComparison.OrdinalIgnoreCase) ||
            msg.Contains("session_locked", StringComparison.OrdinalIgnoreCase) ||
            msg.Contains("session_unlocked", StringComparison.OrdinalIgnoreCase) ||
            msg.Contains("finished", StringComparison.OrdinalIgnoreCase))
            return LogLevel.Information;
        return LogLevel.Debug;
    }
}
