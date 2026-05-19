using System.Collections.Generic;

namespace Aqueous.Features.Bindings;

/// <summary>
/// Stage 7: fire-and-forget process spawn abstraction extracted from the
/// god class. Implementations must never throw and must use
/// <c>UseShellExecute = false</c> (AOT-safe).
/// </summary>
internal interface IProcessLauncher
{
    /// <summary>
    /// Start <paramref name="fileName"/> with the given argument list and
    /// optional environment overrides. Returns <c>true</c> if the
    /// process was started, <c>false</c> on any failure.
    /// </summary>
    bool Start(
        string fileName,
        IReadOnlyList<string>? arguments = null,
        IReadOnlyDictionary<string, string?>? environment = null);
}
