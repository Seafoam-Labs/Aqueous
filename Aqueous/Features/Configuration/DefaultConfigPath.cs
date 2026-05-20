using System;
using System.IO;

namespace Aqueous.Features.Configuration;

/// <summary>
/// PR 9.12 §2.12 — pure helper that resolves the default config path
/// (<c>${XDG_CONFIG_HOME:-~/.config}/aqueous/wm.toml</c>). Previously
/// lived on <c>RiverWindowManagerClient.GetDefaultConfigPath</c>; lifted
/// top-level so config-path resolution no longer needs the god class.
/// </summary>
internal static class DefaultConfigPath
{
    /// <summary>
    /// Resolves <c>${XDG_CONFIG_HOME:-$HOME/.config}/aqueous/wm.toml</c>.
    /// </summary>
    public static string Resolve()
    {
        var xdg = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME");
        var baseDir = !string.IsNullOrEmpty(xdg)
            ? xdg
            : Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".config");
        return Path.Combine(baseDir, "aqueous", "wm.toml");
    }
}
