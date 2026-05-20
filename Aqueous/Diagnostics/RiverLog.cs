using System;
using Microsoft.Extensions.Logging;

namespace Aqueous.Diagnostics;

/// <summary>
/// Top-level River log sink, lifted out of the soon-to-be-deleted <c>RiverWindowManagerClient</c>
/// god class. Existing call sites that write <c>RiverWindowManagerClient.Log(...)</c> still work
/// because the god class's <c>Log</c> property is now a thin forwarder to <see cref="Write"/>; new
/// code should call <see cref="Write"/> directly so the final deletion of the god class does not
/// require a per-call-site sweep.
/// <para>
/// Behaviour is byte-for-byte equivalent to the prior <c>RiverWindowManagerClient.DefaultLog</c>:
/// messages are routed through <see cref="RiverLogClassifier"/> to pick a <see cref="LogLevel"/>
/// and then emitted via the ambient <see cref="Logging.Factory"/>. The <see cref="Sink"/> property
/// preserves the prior test seam (host code or unit tests may swap the delegate to capture
/// messages).
/// </para>
/// </summary>
internal static class RiverLog
{
    // Log category retargeted to RiverLog itself so that the impending deletion of
    // RiverWindowManagerClient does not orphan this generic argument. The category name surfaces in
    // structured logs as "Aqueous.Diagnostics.RiverLog".
    private static readonly ILogger Logger =
        Logging.Factory.CreateLogger("Aqueous.Diagnostics.RiverLog");

    /// <summary>
    /// Mutable sink. Defaults to <see cref="DefaultWrite"/>; tests and host code may replace it to
    /// intercept messages. Mirrors the prior <c>RiverWindowManagerClient.Log</c> setter contract.
    /// </summary>
    public static Action<string> Sink { get; set; } = DefaultWrite;

    /// <summary>
    /// Emit a free-form River protocol message through the current <see cref="Sink"/>. Tolerates
    /// <c>null</c> by no-oping so callers don't need defensive guards at every call site.
    /// </summary>
    public static void Write(string msg)
    {
        if (msg is null) return;
        Sink(msg);
    }

    private static void DefaultWrite(string msg)
    {
        var level = RiverLogClassifier.Classify(msg);
#pragma warning disable CA1848, CA2254 // call sites pre-date the structured-logging migration
        Logger.Log(level, "{Message}", msg);
#pragma warning restore CA1848, CA2254
    }
}
