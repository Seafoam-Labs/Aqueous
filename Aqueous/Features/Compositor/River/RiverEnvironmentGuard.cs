using System;

namespace Aqueous.Features.Compositor.River;

/// <summary>
/// Stage 9 PR 9.11 — encapsulates the <c>AQUEOUS_RIVER_WM=1</c> opt-in
/// check previously inline in <see cref="RiverWindowManagerClient.TryStart"/>.
///
/// <para>
/// Centralising the check lets <see cref="RiverCompositorHost"/> fail
/// startup with a friendly error message before any DI resolution that
/// would otherwise attempt to open a Wayland connection. Pure function
/// over the process environment — trivially unit-testable by reading
/// <see cref="Environment.GetEnvironmentVariable(string)"/> directly.
/// </para>
/// </summary>
internal static class RiverEnvironmentGuard
{
    /// <summary>Environment variable consulted to opt the WM in. Value must be exactly <c>"1"</c>.</summary>
    internal const string EnvVarName = "AQUEOUS_RIVER_WM";

    /// <summary>
    /// Returns <c>true</c> when <c>AQUEOUS_RIVER_WM=1</c> is set in the
    /// current process environment, indicating the user intends Aqueous
    /// to attach to River as the sole window-management client.
    /// </summary>
    internal static bool IsEnabled() =>
        Environment.GetEnvironmentVariable(EnvVarName) == "1";

    /// <summary>
    /// Friendly failure message used by both <see cref="RiverWindowManagerClient.TryStart"/>
    /// and <see cref="RiverCompositorHost"/> when the opt-in is absent.
    /// </summary>
    internal const string NotEnabledMessage =
        "AQUEOUS_RIVER_WM is not set to 1; refusing to attach as a window manager";
}
